"""Tests for pipelines.vendordrop.ingest — which uploads count as pending.

The drop bucket holds two kinds of object that look alike to a listing: the
reports someone uploaded, and the `.keep` placeholders 09-vendor-drop.sh
writes so the folders are visible in the console. Only object size separates
them, and getting that wrong is not a quiet failure — a placeholder that
reaches the PDF extractor raises, and the invoice behind it never loads.
"""

import sys
import types
import unittest

# `pending_blobs` imports google.api_core lazily, to name the two exceptions
# it treats as "not configured yet". CI installs no cloud libraries — the rest
# of the suite runs on the standard library — so stub the module rather than
# add a dependency for two exception classes.
if "google.api_core" not in sys.modules:
    _exc = types.ModuleType("google.api_core.exceptions")
    _exc.NotFound = type("NotFound", (Exception,), {})
    _exc.Forbidden = type("Forbidden", (Exception,), {})
    _api_core = types.ModuleType("google.api_core")
    _api_core.exceptions = _exc
    _google = types.ModuleType("google")
    _google.api_core = _api_core
    sys.modules.setdefault("google", _google)
    sys.modules["google.api_core"] = _api_core
    sys.modules["google.api_core.exceptions"] = _exc

from pipelines.vendordrop import ingest


class FakeBlob:
    def __init__(self, name, size, created):
        self.name, self.size, self.time_created = name, size, created


class FakeBucket:
    name = "livewire-dw-vendor-drops"

    def __init__(self, blobs):
        self._blobs = blobs

    def list_blobs(self, prefix):
        return [b for b in self._blobs if b.name.startswith(prefix)]


class TestPendingBlobs(unittest.TestCase):
    def test_zero_byte_placeholder_is_not_an_upload(self):
        # 09-vendor-drop.sh must write .keep at zero bytes. A one-byte file
        # (a stray newline, say) is indistinguishable from a real upload and
        # is handed to the parser for that prefix.
        bucket = FakeBucket([
            FakeBlob("parasol/invoice/.keep", 0, 1),
            FakeBlob("parasol/invoice/INV031247.pdf", 88_000, 2),
        ])
        pending = ingest.pending_blobs(bucket, "parasol/invoice", "livewire")
        self.assertEqual([b.name for b in pending],
                         ["parasol/invoice/INV031247.pdf"])

    def test_a_one_byte_placeholder_would_be_parsed(self):
        # Pins the failure this test exists for: size is the ONLY thing that
        # keeps a placeholder out of the parser — not its name, not .keep.
        bucket = FakeBucket([FakeBlob("parasol/invoice/.keep", 1, 1)])
        pending = ingest.pending_blobs(bucket, "parasol/invoice", "livewire")
        self.assertEqual(len(pending), 1)

    def test_oldest_first(self):
        # Uploads land in order, so a corrected re-upload lands after the file
        # it corrects and staging's latest-row-wins keeps the right one.
        bucket = FakeBucket([
            FakeBlob("alarmdotcom/customerlist/b.csv", 10, 2),
            FakeBlob("alarmdotcom/customerlist/a.csv", 10, 1),
        ])
        pending = ingest.pending_blobs(bucket, "alarmdotcom/customerlist",
                                       "livewire")
        self.assertEqual([b.name for b in pending],
                         ["alarmdotcom/customerlist/a.csv",
                          "alarmdotcom/customerlist/b.csv"])

    def test_directory_markers_are_skipped(self):
        # The console's "Create folder" writes a zero-byte object ending in /.
        bucket = FakeBucket([FakeBlob("parasol/invoice/", 0, 1)])
        self.assertEqual(
            ingest.pending_blobs(bucket, "parasol/invoice", "livewire"), [])


class UploadBlob:
    def __init__(self, name, data):
        self.name, self.data, self.deleted = name, data, False

    def download_as_bytes(self):
        return self.data

    def delete(self):
        self.deleted = True


class ArchiveBucket:
    name = "livewire-dw-vendor-drops"

    def __init__(self):
        self.copies = []

    def copy_blob(self, blob, bucket, new_name):
        self.copies.append(new_name)


# The Customer Count as Manitou sends it, and the same report after someone
# opened it in TextEdit and saved it: what actually happened on 2026-09-28.
CUSTOMERCOUNT = (
    "sep=,\r\n"
    '2311636,"William Goodrum (Cottage) [A1651/1857]",Active,3/14/2019\r\n'
    "0,1,520,67\r\n"
).encode("utf-8")
AS_RTF = (b"{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n"
          b"\\f0\\fs24 \\cf0 sep=,\\\n2311636,William Goodrum,Active,3/14/2019\\\n}")


class TestHandleUpload(unittest.TestCase):
    KEY = "securitycentral/customercount"

    def run_one(self, name, data):
        bucket, blob, landed = ArchiveBucket(), UploadBlob(name, data), []
        result = ingest.handle_upload(
            bucket, blob, self.KEY, lambda recs: landed.append(recs) or len(recs))
        return result, bucket, blob, landed

    def test_a_real_report_lands_and_is_archived_as_processed(self):
        (rows, dest, error), _, blob, landed = self.run_one(
            f"{self.KEY}/45779342.CSV", CUSTOMERCOUNT)
        self.assertIsNone(error)
        self.assertEqual(rows, 1)
        self.assertEqual(len(landed), 1)
        self.assertTrue(dest.startswith(f"processed/{self.KEY}/"))
        self.assertTrue(blob.deleted)

    def test_a_file_with_no_records_is_rejected_not_processed(self):
        (rows, dest, error), bucket, blob, landed = self.run_one(
            f"{self.KEY}/customer count livewire.rtf", AS_RTF)
        self.assertEqual(rows, 0)
        self.assertEqual(landed, [], "nothing may be landed from a rejected file")
        self.assertTrue(dest.startswith(f"rejected/{self.KEY}/"), dest)
        self.assertEqual(bucket.copies, [dest])
        self.assertTrue(blob.deleted, "the folder must be clear for the re-upload")
        self.assertIsNotNone(error)

    def test_the_rejection_names_rich_text(self):
        (_, _, error), *_ = self.run_one(f"{self.KEY}/x.rtf", b"  " + AS_RTF)
        self.assertIn(".rtf", error)
        self.assertIn("exactly as the vendor sent it", error)

    def test_any_other_empty_file_names_the_layout(self):
        (_, _, error), *_ = self.run_one(f"{self.KEY}/notes.csv", b"a,b\r\nc,d\r\n")
        self.assertIn(self.KEY, error)
        self.assertNotIn("rich-text", error)


class TestRunFails(unittest.TestCase):
    """main() must end red when anything was rejected, after loading the rest."""

    def test_main_exits_nonzero_listing_rejected_files(self):
        src = open(ingest.__file__).read()
        body = src[src.index("def main():"):]
        self.assertIn("if rejected:", body)
        tail = body[body.index("if rejected:"):]
        self.assertIn("raise SystemExit(", tail)
        self.assertLess(body.index('log.info("done:'), body.index("if rejected:"),
                        "the run must finish every other upload before failing")


if __name__ == "__main__":
    unittest.main()

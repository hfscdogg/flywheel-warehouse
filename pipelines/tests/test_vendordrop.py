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


if __name__ == "__main__":
    unittest.main()

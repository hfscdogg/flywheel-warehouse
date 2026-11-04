"""Vendor reports from Drive folders land exactly where uploads of them do."""

import unittest

from pipelines.drivedrop import ingest
from pipelines.lib import tabular


class Config(unittest.TestCase):
    def test_parses_format_to_folder(self):
        self.assertEqual(ingest.parse_config("parasol/invoice=F1"), {"parasol/invoice": "F1"})
        self.assertEqual(ingest.parse_config(None), {})

    def test_an_unknown_format_is_refused(self):
        with self.assertRaises(SystemExit):
            ingest.parse_config("parasol/invoices=F1")
        with self.assertRaises(SystemExit):
            ingest.parse_config("parasol/invoice")

    def test_livewire_drops_name_known_formats(self):
        from pipelines.lib import config
        drops = ingest.parse_config(config.load_client("livewire").env.get("DRIVE_DROPS"))
        self.assertIn("parasol/invoice", drops)
        for fmt_key in drops:
            self.assertIn(fmt_key, tabular.FORMATS)


class Plan(unittest.TestCase):
    def test_new_files_only_and_folders_ignored(self):
        files = [
            {"id": "a", "name": "INV-1.pdf", "md5Checksum": "1", "size": "10"},
            {"id": "b", "name": "INV-2.pdf", "md5Checksum": "2", "size": "10"},
            {"id": "c", "name": "old", "mimeType": "application/vnd.google-apps.folder"},
            {"id": "d", "name": "huge.pdf", "md5Checksum": "4", "size": str(ingest.MAX_BYTES + 1)},
        ]
        to_load, skipped = ingest.plan(files, {"a:1"})
        self.assertEqual([f["id"] for f in to_load], ["b"])
        self.assertEqual(skipped, [("huge.pdf", "over the size cap")])

    def test_lands_in_the_table_staging_reads(self):
        # The Drive route writes tabular.table_name(fmt), the very table a
        # bucket upload of the same format writes; staging must read it.
        import pathlib
        root = pathlib.Path(__file__).resolve().parents[2]
        model = (root / "sql" / "staging" / "stg_vendor__parasol_accounts.sql").read_text()
        self.assertIn(f"raw_vendor.{tabular.table_name('parasol/invoice')}", model)


class Script(unittest.TestCase):
    def test_the_apps_script_saves_into_the_configured_folders(self):
        import pathlib
        from pipelines.lib import config
        root = pathlib.Path(__file__).resolve().parents[2]
        script = (root / "scripts" / "apps-script" / "save-vendor-documents.gs").read_text()
        env = config.load_client("livewire").env
        for folder in list(ingest.parse_config(env.get("DRIVE_DROPS")).values()) + [
                env.get("SC_STATEMENT_DRIVE_FOLDER_ID")]:
            self.assertIn(folder, script)
        # The installed trigger calls this name; renaming it would silently
        # stop the daily save.
        self.assertIn("function saveSecurityCentralStatements()", script)


if __name__ == "__main__":
    unittest.main()

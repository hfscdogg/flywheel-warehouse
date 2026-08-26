"""Tests for client config loading — stdlib only."""

import unittest

from pipelines.lib import config


class TestClientConfig(unittest.TestCase):
    def test_livewire_loads(self):
        cfg = config.load_client("livewire")
        self.assertEqual(cfg.project_id, "livewire-dw")
        self.assertEqual(cfg.bq_location, "US")
        self.assertEqual(
            cfg.raw_datasets,
            ["raw_zoho", "raw_zohobilling", "raw_dtools", "raw_qbo"],
        )

    def test_source_enablement(self):
        cfg = config.load_client("livewire")
        self.assertEqual(cfg.raw_dataset_for("zoho"), "raw_zoho")
        self.assertEqual(cfg.raw_dataset_for("zohobilling"), "raw_zohobilling")
        self.assertIsNone(cfg.raw_dataset_for("hubspot"))

    def test_unknown_client(self):
        with self.assertRaises(FileNotFoundError):
            config.load_client("nonexistent")

    def test_missing_required_var(self):
        with self.assertRaises(ValueError):
            config.ClientConfig({"CLIENT_SLUG": "x"})


if __name__ == "__main__":
    unittest.main()

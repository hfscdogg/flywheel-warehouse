"""runner.land logs every run, empty pulls included -- stdlib only.

sql/checks/fresh.sql decides an incremental source is current from this log,
because its landing table only grows when a record changes. An empty pull that
logs nothing is the failure this exists to prevent: 2026-09-25, QuickBooks
purchase orders reported "ingest workflow has not run" after three green runs.
"""

import unittest

from pipelines.lib import runner


class FakeBqMod:
    LANDING_SCHEMA = []

    def __init__(self, fail_load=False):
        self.fail_load = fail_load
        self.runs = []
        self.watermarks = []

    def ensure_table(self, bq, cfg, dataset, name, schema):
        return f"p.{dataset}.{name}"

    def load_rows(self, bq, table_id, rows, schema):
        if self.fail_load:
            raise RuntimeError("load failed")
        return len(rows)

    def set_watermark(self, bq, cfg, dataset, entity, watermark, run_id, recorded_at):
        self.watermarks.append(entity)

    def record_run(self, bq, cfg, dataset, entity, run_id, rows_loaded, ran_at):
        self.runs.append((dataset, entity, run_id, rows_loaded))


RECORDS = [{"Id": "1", "MetaData": {"LastUpdatedTime": "2026-09-22T10:00:00-07:00"}}]


def land(mod, records):
    return runner.land(mod, None, None, "raw_qbo", "PurchaseOrder", records,
                       "Id", "MetaData.LastUpdatedTime", "qbo-run")


class LandLogsTheRun(unittest.TestCase):
    def test_an_empty_pull_is_still_logged(self):
        mod = FakeBqMod()
        self.assertEqual(land(mod, []), 0)
        self.assertEqual(mod.runs, [("raw_qbo", "purchaseorder", "qbo-run", 0)])

    def test_a_pull_with_records_is_logged_with_its_count(self):
        mod = FakeBqMod()
        self.assertEqual(land(mod, RECORDS), 1)
        self.assertEqual(mod.runs, [("raw_qbo", "purchaseorder", "qbo-run", 1)])

    def test_the_log_names_the_landing_table_not_the_api_entity(self):
        # fresh.sql joins the log to the raw table a staging model reads,
        # raw_qbo.purchaseorder, never the API's PurchaseOrder.
        mod = FakeBqMod()
        land(mod, [])
        self.assertEqual(mod.runs[0][1], "purchaseorder")

    def test_a_failed_load_is_not_logged_as_a_run(self):
        mod = FakeBqMod(fail_load=True)
        with self.assertRaises(RuntimeError):
            land(mod, RECORDS)
        self.assertEqual(mod.runs, [])


if __name__ == "__main__":
    unittest.main()

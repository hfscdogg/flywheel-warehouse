"""The statement marts are QuickBooks' own figures, and the transform proves
they agree with each other before anyone reads them.

The accountant's August 2026 package was internally inconsistent twice: a
trend report that repeated a month, then P&L pages and balance-sheet pages
run on different days, $3,140 apart on year-to-date net income. The
warehouse version of that package is kpi_financial_statements and
kpi_financial_monthly, and sql/checks/qbo_reports_tie.sql is what makes
either failure impossible to serve quietly. These tests keep that check
wired in and keep its assertions from being edited away one at a time.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
TIE = ROOT / "sql" / "checks" / "qbo_reports_tie.sql"
TRANSFORM = ROOT / "scripts" / "06-transform.sh"
LINES = ROOT / "sql" / "staging" / "stg_qbo__report_lines.sql"
STATEMENTS = ROOT / "sql" / "marts" / "kpi_financial_statements.sql"
MONTHLY = ROOT / "sql" / "marts" / "kpi_financial_monthly.sql"


def flat(text):
    return " ".join(re.sub(r"--[^\n]*", "", text).split())


def function_body(src, name):
    body = src[src.index(f"{name}() {{"):]
    return body[:body.index("\n}\n")]


class TheTransformRunsTheTie(unittest.TestCase):

    def setUp(self):
        self.src = TRANSFORM.read_text()
        self.flat = " ".join(self.src.split())

    def test_it_is_called(self):
        self.assertIn("check_reports_tie() {", self.flat)
        self.assertIn(" check_reports_tie ", self.flat,
                      "check_reports_tie is defined but never called")

    def test_it_runs_after_the_build_and_before_freshness(self):
        # check_fresh dies whenever any feed is late, which is most days
        # (issue #63). A tie failure placed after it would never be reported.
        call = self.flat.rindex(" check_reports_tie ")
        self.assertLess(self.flat.rindex(" check_described "), call)
        self.assertLess(call, self.flat.rindex(" check_fresh "),
                        "the tie runs after check_fresh, so a stale upload "
                        "anywhere hides a disagreement in the books")

    def test_a_disagreement_ends_the_run_red(self):
        body = function_body(self.src, "check_reports_tie")
        self.assertIn("qbo_reports_tie.sql", body)
        self.assertIn("die ", body)

    def test_a_client_without_quickbooks_reports_is_skipped(self):
        body = function_body(self.src, "check_reports_tie")
        self.assertIn("table_present staging.stg_qbo__report_lines", body,
                      "a client with no QuickBooks reports would fail the "
                      "transform on a table that does not exist")


class TheTieAssertsEachAgreement(unittest.TestCase):
    """Each of the five agreements, by what it compares."""

    def setUp(self):
        self.sql = flat(TIE.read_text())

    def assertCompares(self, computed, printed):
        pattern = (re.escape(computed) + r"(?: AS computed)?, "
                   + re.escape(printed) + r"(?: AS printed)?")
        self.assertRegex(self.sql, pattern)

    def test_1_profit_and_loss_arithmetic(self):
        self.assertCompares("income - cogs", "gross_profit")
        self.assertCompares("gross_profit - expenses", "net_operating_income")
        self.assertCompares("other_income - other_expenses", "net_other_income")
        self.assertCompares("net_operating_income + net_other_income", "net_income")

    def test_2_cash_flow_opens_with_net_income(self):
        self.assertCompares("m.net_income", "n.cash_flow_net_income")

    def test_3_balance_sheet_carries_the_year_to_date(self):
        self.assertCompares("y.net_income_ytd", "n.balance_sheet_net_income")
        # Year to date means within the calendar year, not running forever.
        self.assertIn("PARTITION BY EXTRACT(YEAR FROM period_start) ORDER BY period_start",
                      self.sql)

    def test_4_the_balance_sheet_balances(self):
        self.assertCompares("total_assets", "total_liabilities_equity")

    def test_5_accounts_add_up_to_their_section(self):
        self.assertCompares("a.amount", "t.amount")
        self.assertIn("WHERE line_type = 'account'", self.sql)

    def test_a_missing_side_is_a_failure_not_a_pass(self):
        # NULL - x is NULL and NULL > 0.01 is not true: without IFNULL a
        # report that stopped landing would pass every check.
        self.assertIn(
            "WHERE ABS(IFNULL(computed, 0) - IFNULL(printed, 0)) > 0.01", self.sql)


class TheMartsReadTheNewestPull(unittest.TestCase):

    def test_staging_keeps_only_the_newest_load_of_each_report(self):
        # Every run lands three years again. Without this, each month is
        # counted once per run.
        sql = flat(LINES.read_text())
        self.assertIn("MAX(_loaded_at) AS loaded_at FROM raw_qbo.report_lines GROUP BY report",
                      sql)
        self.assertIn("l._loaded_at = n.loaded_at", sql)


class TheBudgetIsTheActivePlan(unittest.TestCase):

    def test_statements_put_budget_on_profit_and_loss_accounts_only(self):
        sql = flat(STATEMENTS.read_text())
        self.assertIn("WHERE is_active AND budget_type = 'ProfitAndLoss'", sql)
        # On a total line the budget would be one account's figure beside a
        # section's actual.
        self.assertIn(
            "IF(l.report = 'ProfitAndLoss' AND l.line_type = 'account', b.budget_amount, NULL)",
            sql)

    def test_monthly_uses_the_active_budget(self):
        self.assertIn("WHERE b.is_active AND b.budget_type = 'ProfitAndLoss'",
                      flat(MONTHLY.read_text()))

    def test_monthly_reads_printed_totals_not_resums(self):
        sql = flat(MONTHLY.read_text())
        self.assertIn(
            "group_totals AS ( SELECT report, report_group, period_start, amount "
            "FROM lines WHERE line_type = 'total'", sql)


if __name__ == "__main__":
    unittest.main()

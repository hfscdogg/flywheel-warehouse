"""Tests for pipelines.lib.tabular — vendor report parsing.

These reports are shaped for human eyes, and the failure mode that matters is
silent: a summary row parsed as a customer, or columns shifted by one, both
produce plausible-looking records that quietly corrupt the audit. The fixtures
below are trimmed from the real 2026-08-27 exports, including the rows that
caused trouble.
"""

import io
import unittest
import zipfile

from pipelines.lib import tabular
from pipelines.tests.test_pdftext_rows import pdf

# The "Customer Count" report as Manitou emits it: a `sep=,` preamble, no
# header row, and a trailing counts row whose four values are a red herring
# ("0, 1, 520, 67" has exactly the right shape for a record).
CUSTOMERCOUNT = (
    "sep=,\r\n"
    '2311636,"William Goodrum (Cottage) [A1651/1857]",Active,3/14/2019\r\n'
    '1088430,"Pellock, Mr./Mrs. [A1000-2496]",Active,7/2/2015\r\n'
    '1044907,"Old Account [A1000-3311]",Deactivated,1/9/2011\r\n'
    "0,1,520,67\r\n"
).encode("utf-8")


def _xlsx(rows):
    """Minimal .xlsx bytes with inline strings, for the All Accounts shape."""
    def cell(col, value):
        ref = f"{chr(65 + col)}1"
        return (f'<c r="{ref}" t="inlineStr"><is><t>{value}</t></is></c>'
                if value else f'<c r="{ref}"/>')

    body = "".join(
        f'<row>{"".join(cell(i, v) for i, v in enumerate(r))}</row>' for r in rows)
    sheet = ('<?xml version="1.0"?><worksheet xmlns="http://schemas.'
             f'openxmlformats.org/spreadsheetml/2006/main"><sheetData>{body}'
             "</sheetData></worksheet>")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("xl/worksheets/sheet1.xml", sheet)
    return buf.getvalue()


ALLACCOUNTS = _xlsx([
    ["ACCOUNT", "CONTRACT", "SUBSCRIBER", "STATUS", "TYPE", "STARTED", "CONTACT"],
    ["ACCOUNT: A1000-2496", "", "", "", "", "", ""],   # report separator row
    ["A1000-2496", "1088430", "Mr./Mrs. Pellock|13413 Langford Dr||Midlothian, VA 23113",
     "Active", "Residential", "2015-07-02 00:00:00", "804-555-0100"],
    ["A1000-2496", "1088430", "Mr./Mrs. Pellock|13413 Langford Dr||Midlothian, VA 23113",
     "Active", "Residential", "2015-07-02 00:00:00", "804-555-0101"],
    ["A1651-1857", "2311636", "William Goodrum|9 Cottage Ln||Richmond, VA 23226",
     "Active", "Residential", "2019-03-14 00:00:00", "804-555-0102"],
])


class TestCustomerCount(unittest.TestCase):
    KEY = "securitycentral/customercount"

    def setUp(self):
        self.records = tabular.parse(CUSTOMERCOUNT, "45779342.CSV", self.KEY)

    def test_drops_preamble_and_summary_row(self):
        # Four data-shaped lines in, three real records out: `sep=,` is a
        # preamble and "0,1,520,67" is the counts row.
        self.assertEqual(len(self.records), 3)
        self.assertNotIn("1", [r["SUBSCRIBER"] for r in self.records])

    def test_columns_are_named_by_the_spec_not_the_first_row(self):
        # The file has no header, so a header-sniffing parser would eat the
        # first customer and label everything with their data.
        self.assertEqual(self.records[0], {
            "CONTRACT": "2311636",
            "SUBSCRIBER": "William Goodrum (Cottage) [A1651/1857]",
            "STATUS": "Active",
            "STARTED": "3/14/2019",
        })

    def test_keeps_deactivated_accounts(self):
        # DEACTIVATED is a finding in the audit, not noise to filter here.
        self.assertIn("Deactivated", [r["STATUS"] for r in self.records])

    def test_id_and_table(self):
        self.assertEqual(tabular.id_column(self.KEY), "CONTRACT")
        self.assertEqual(tabular.table_name(self.KEY), "securitycentral_status")


class TestAllAccounts(unittest.TestCase):
    KEY = "securitycentral/allaccounts"

    def setUp(self):
        self.records = tabular.parse(ALLACCOUNTS, "AllAccounts.xlsx", self.KEY)

    def test_drops_separator_rows_keeps_every_contact_row(self):
        # "ACCOUNT: A1000-2496" is a separator; the two Pellock rows are the
        # same account with two phone numbers and both are real records
        # (staging dedups to one row per account, not this parser).
        self.assertEqual(len(self.records), 3)
        self.assertEqual(len({r["ACCOUNT"] for r in self.records}), 2)

    def test_header_row_names_the_columns(self):
        self.assertEqual(self.records[0]["ACCOUNT"], "A1000-2496")
        self.assertEqual(self.records[0]["CONTRACT"], "1088430")
        self.assertEqual(self.records[0]["TYPE"], "Residential")

    def test_id_and_table_match_the_cli_loader(self):
        # scripts/08-vendor-roster.sh lands the same export in the same table
        # keyed the same way; a browser upload and a CLI load must be
        # interchangeable or staging would see two disjoint rosters.
        self.assertEqual(tabular.id_column(self.KEY), "ACCOUNT")
        self.assertEqual(tabular.table_name(self.KEY), "securitycentral_accounts")


class TestFormatSpecs(unittest.TestCase):
    def test_unknown_format_fails_loudly(self):
        with self.assertRaises(ValueError):
            tabular.parse(b"a,b\n1,2\n", "x.csv", "securitycentral/nope")

    def test_every_format_is_complete(self):
        # A spec missing a key would fail at ingest time, in a scheduled job.
        for key, spec in tabular.FORMATS.items():
            with self.subTest(key=key):
                self.assertIn("/", key, "keys are '<vendor>/<report>' drop prefixes")
                self.assertTrue(spec["table"].isidentifier())
                self.assertTrue(spec["id_column"])
                if spec["columns"]:
                    self.assertIn(spec["id_column"], spec["columns"])

    def test_tables_are_distinct(self):
        tables = [s["table"] for s in tabular.FORMATS.values()]
        self.assertEqual(len(tables), len(set(tables)))


class TestNormalizeStreet(unittest.TestCase):
    """Parasol writes addresses three ways; two of them never match unkeyed."""

    def test_leading_number_is_left_alone(self):
        self.assertEqual(tabular.normalize_street("4830 Old Main St"),
                         "4830 Old Main St")

    def test_trailing_number_moves_to_the_front(self):
        # Verified against a household that also appears in the Security
        # Central roster as "629 Longfield Rd" — the reversal recovers the
        # real address rather than inventing one.
        self.assertEqual(tabular.normalize_street("Longfield Road 629"),
                         "629 Longfield Road")

    def test_wrapped_name_prefix_is_dropped(self):
        # A long commercial name wraps onto the address run; the address
        # starts at the LAST number followed by words, not the first.
        self.assertEqual(tabular.normalize_street("and 351 6802 Paragon Pl"),
                         "6802 Paragon Pl")

    def test_no_number_anywhere_is_unchanged(self):
        # Unmatchable, and that is the honest outcome — the account still
        # lands and shows up in the audit as one we are billed for.
        self.assertEqual(tabular.normalize_street("Maple Ave"), "Maple Ave")

    def test_empty(self):
        self.assertEqual(tabular.normalize_street(""), "")


class TestAccountKey(unittest.TestCase):
    """Parasol numbers no accounts, so the key is synthesised — and a
    collision silently drops an account we are paying for."""

    def test_distinguishes_households_sharing_a_zip_with_no_house_number(self):
        # These three collapsed onto one key when it was built from house
        # number and ZIP alone; two of the three would have vanished.
        keys = {
            tabular.account_key("Merchant, Barbara", "Maple Ave", "Richmond VA 23226", "Home"),
            tabular.account_key("Koval, Patte", "5305 Kingsbury Road", "Richmond Virginia 23226", "Home"),
            tabular.account_key("Nelson, Jack", "11 Mary View Drive", "Richmond Virginia 23226", "Home"),
        }
        self.assertEqual(len(keys), 3)

    def test_stable_for_the_same_account(self):
        args = ("Beale, Frank", "4830 Old Main St", "Richmond, VA 23231", "Home")
        self.assertEqual(tabular.account_key(*args), tabular.account_key(*args))

    def test_never_empty(self):
        self.assertTrue(tabular.account_key("", "", "", ""))


class TestNewFormats(unittest.TestCase):
    def test_parasol_and_alarmdotcom_specs_are_registered(self):
        self.assertEqual(tabular.table_name("parasol/invoice"), "parasol_accounts")
        self.assertEqual(tabular.table_name("alarmdotcom/customerlist"),
                         "alarmdotcom_accounts")

    def test_preamble_rows_never_become_the_header(self):
        # The Alarm.com export opens with several single-cell lines. If one
        # is taken as the header, every record is dropped — which is exactly
        # what happened before the check moved ahead of header assignment.
        csv = (b'"Data as of 8/31/2026"\n\n"Monitoring Station = Any"\n\n'
               b'Customer ID,First Name,Postal Code\n'
               b'123,Ada,23230\n')
        recs = tabular.parse(csv, "Custom_List.csv", "alarmdotcom/customerlist")
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]["Customer ID"], "123")


if __name__ == "__main__":
    unittest.main()


# One customer of Security Central's "Customer System Recurring" report, laid
# out as the real thing lays it out — including the three things that broke a
# first pass at reading it:
#   * a customer name long enough to wrap, whose packed cell is drawn to the
#     LEFT of its own "Customer No.:" label and whose tail lands on the next
#     line;
#   * a payment method that wraps the same way ("BANK-" / "DRAFT");
#   * a yearly resource, whose amount prints to five decimals because the
#     column is already reduced to a month, and a row with no Manitou CommNo.
def _sc_recurring_pdf():
    runs = [
        (250, 700, "Security Central"),
        # Wrapped name: value left of its label, tail on the line below.
        (30, 660, "000312-10616  EVAN SHERWOOD - INDOOR SPORTS"),
        (180, 660, "Customer No.:"),
        (330, 660, "Monitoring No.:"),
        (420, 660, "2155528"),
        (470, 660, "Dealer:"),
        (520, 660, "10191"),
        (30, 650, "FACILITY"),
        (30, 630, "MON"), (67, 630, "Monitoring"), (181, 630, "01/21/22"),
        (220, 630, "09/25/26"), (258, 630, "10/01/26"), (300, 630, "1M"),
        (330, 630, "5.00"), (380, 630, "No"), (420, 630, "No"),
        (460, 630, "1"), (500, 630, "A1651 1687"),
        # No CommNo on this line: ten cells where the last one has eleven.
        (30, 620, "TMO"), (67, 620, "Test Monthly"), (181, 620, "01/21/22"),
        (220, 620, "09/25/26"), (258, 620, "10/01/26"), (300, 620, "1M"),
        (330, 620, "0.00"), (380, 620, "No"), (420, 620, "No"),
        (500, 620, "A1651 1687"),
        # Direct-billed customer: wrapped payment method, and a Bill Price
        # that is money on a customer line and must not be read as a rate.
        (30, 580, "BANK-"),
        (180, 580, "Customer No.:"),
        (200, 580, "C0138248  ANDREW HICKSON"),
        (330, 580, "Monitoring No.:"), (420, 580, "2132059"),
        (470, 580, "Dealer:"), (520, 580, "10191"),
        (560, 580, "Pmt Mthd:"), (600, 580, "Bill Price:"), (640, 580, "30.00"),
        (30, 570, "DRAFT"),
        (30, 550, "MON"), (67, 550, "Monitoring"), (181, 550, "05/20/19"),
        (220, 550, "10/25/26"), (258, 550, "11/01/26"), (300, 550, "1Y"),
        (330, 550, "4.58333"), (380, 550, "No"), (420, 550, "No"),
        (460, 550, "1"), (500, 550, "A2293 1006"),
    ]
    return pdf(runs)


class SecurityCentralRecurring(unittest.TestCase):
    def setUp(self):
        self.records = tabular.parse(_sc_recurring_pdf(), "Recurring.pdf",
                                     "securitycentral/recurring")

    def test_one_row_per_resource_not_per_account(self):
        # The account with two resources contributes two rows. Reading one row
        # as the account's cost is the mistake this grain exists to prevent.
        self.assertEqual(len(self.records), 3)
        self.assertEqual([r["RESOURCE"] for r in self.records],
                         ["MON", "TMO", "MON"])

    def test_wrapped_customer_name_is_rejoined(self):
        # Drawn as three pieces across two lines, one of them to the left of
        # its own label. The audit matches customers by name, so a name that
        # stops at "INDOOR SPORTS" matches nothing.
        self.assertEqual(self.records[0]["SUBSCRIBER"],
                         "EVAN SHERWOOD - INDOOR SPORTS FACILITY")
        self.assertEqual(self.records[0]["CUSTOMER_NO"], "000312-10616")

    def test_wrapped_payment_method_is_not_taken_for_the_name(self):
        # "DRAFT" lands exactly where a wrapped name would; the hyphen the
        # method breaks on is what separates them.
        self.assertEqual(self.records[2]["SUBSCRIBER"], "ANDREW HICKSON")
        self.assertEqual(self.records[2]["PMT_METHOD"], "BANK-DRAFT")

    def test_bill_price_is_the_customers_price_not_our_rate(self):
        self.assertEqual(self.records[2]["BILL_PRICE"], "30.00")
        self.assertEqual(self.records[2]["MONTHLY_AMOUNT"], "4.58333")

    def test_yearly_amount_is_kept_as_the_monthly_figure_it_already_is(self):
        # 4.58333 is $55 a year over 12. The vendor did the division; doing it
        # again here would price the account at 38 cents.
        yearly = self.records[2]
        self.assertEqual(yearly["FRQ"], "1Y")
        self.assertEqual(yearly["MONTHLY_AMOUNT"], "4.58333")

    def test_account_number_is_normalized_to_join_the_roster(self):
        # Printed "A1651 1687"; the roster and the weekly feed both use a
        # hyphen, and the audit joins on it.
        self.assertEqual(self.records[0]["ACCOUNT"], "A1651-1687")

    def test_missing_commno_does_not_shift_the_account_number(self):
        # The row with no CommNo has one fewer cell. Read by position, the
        # sub-account would come out of the wrong slot.
        self.assertEqual(self.records[1]["ACCOUNT"], "A1651-1687")

    def test_line_keys_are_unique(self):
        keys = [r["LINE_KEY"] for r in self.records]
        self.assertEqual(len(set(keys)), len(keys))

    def test_id_and_table(self):
        self.assertEqual(tabular.id_column("securitycentral/recurring"), "LINE_KEY")
        self.assertEqual(tabular.table_name("securitycentral/recurring"),
                         "securitycentral_recurring")


# Alarm.com's billing export: UTF-16, tab-separated, one row per charge. The
# account here carries a base fee and two add-ons, one of them free, plus a
# one-off activation fee that is not part of a monthly rate.
ADC_BILLING = (
    "Charge Amount\tCharge Description\tCharge Type\tCharge Date\t"
    "Customer ID\tFirst Name\tLast Name\r\n"
    "8.27\tMonthly Fee\tFutureService\t2026-09-01\t8345792\tDaniil\tKleyman\r\n"
    "7.60\tAdd-on: Doorbell Cameras\tFutureService\t2026-09-01\t8345792\tDaniil\tKleyman\r\n"
    "0.00\tAdd-on: Locks\tFutureService\t2026-09-01\t8345792\tDaniil\tKleyman\r\n"
    "25.00\tActivation Fee\tActivation\t2026-08-13\t8345792\tDaniil\tKleyman\r\n"
    "5.00\tMonthly Fee\tFutureService\t2026-09-01\t6616436\tMort\tMumma\r\n"
).encode("utf-16")


class AlarmDotComBilling(unittest.TestCase):
    def setUp(self):
        self.records = tabular.parse(ADC_BILLING, "ServiceExcel1.csv",
                                     "alarmdotcom/billing")

    def test_utf16_and_tabs_are_detected(self):
        # Decoded as UTF-8 or split on commas, every row is one unusable cell
        # and the parse yields nothing while raising nothing.
        self.assertEqual(len(self.records), 5)
        self.assertEqual(self.records[0]["Charge Description"], "Monthly Fee")

    def test_one_row_per_charge_not_per_account(self):
        # The point of the grain: this account's monthly cost is 15.87, and
        # no single row says so.
        account = [r for r in self.records if r["Customer ID"] == "8345792"]
        self.assertEqual(len(account), 4)
        recurring = sum(float(r["Charge Amount"]) for r in account
                        if r["Charge Type"] == "FutureService")
        self.assertEqual(recurring, 15.87)

    def test_free_add_on_rows_are_kept(self):
        # A 0.00 add-on is a real line: it says the account has the feature,
        # which is what makes two accounts on one package cost differently.
        self.assertIn("0.00", [r["Charge Amount"] for r in self.records])

    def test_charge_keys_are_unique(self):
        keys = [r["CHARGE_KEY"] for r in self.records]
        self.assertEqual(len(set(keys)), len(keys))
        self.assertEqual(self.records[0]["CHARGE_KEY"],
                         "8345792-Monthly Fee-2026-09-01")

    def test_id_and_table(self):
        self.assertEqual(tabular.id_column("alarmdotcom/billing"), "CHARGE_KEY")
        self.assertEqual(tabular.table_name("alarmdotcom/billing"),
                         "alarmdotcom_billing")


class CsvDialect(unittest.TestCase):
    def test_comma_files_still_parse_as_commas(self):
        # The tab detection must not change how the existing reports read.
        # (The `sep=,` line survives csv_rows as a two-cell row and is dropped
        # by parse() as a single-populated-cell row, which is unchanged here.)
        rows = list(tabular.csv_rows(CUSTOMERCOUNT))
        self.assertEqual(rows[1][0], "2311636")
        self.assertEqual(len(rows[1]), 4)

    def test_a_preamble_does_not_pick_the_delimiter(self):
        data = b"Data as of 8/31/2026\r\na\tb\tc\r\n1\t2\t3\r\n"
        self.assertEqual(list(tabular.csv_rows(data))[-1], ["1", "2", "3"])

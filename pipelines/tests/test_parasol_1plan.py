"""Parasol's invoice since October 2026, issued through 1Plan.

The fixtures are built here, run by run, with invented names: a real invoice
is a client roster and does not belong in the repository. Each run is drawn
as a hex string, the way 1Plan's generator writes every one of them.
"""
import unittest

from pipelines.lib import pdftext, tabular


def pdf(runs):
    """A minimal PDF whose one content stream draws `runs` as hex strings."""
    ops = b"".join(b"BT /F1.0 9 Tf <" + r.encode("latin-1").hex().encode() + b"> Tj ET\n"
                   for r in runs)
    return (b"%PDF-1.3\n1 0 obj\n<< /Length " + str(len(ops)).encode() + b" >>\nstream\n"
            + ops + b"endstream\nendobj\n%%EOF\n")


HEADER = ["INVOICE", "IN0000001", "FROM", "1Plan", "Parasol Monitoring Services",
          "BILLED TO", "Livewire, LLC", "SUMMARY"]


def account(client, location, address, ovrc, amount, wrap=None):
    runs = [client, location] + ([address] if address else []) + [ovrc]
    return runs + ([wrap] if wrap else []) + [amount]


def invoice(enhanced, essential, enhanced_subtotal="49.98", essential_subtotal="13.99",
            enhanced_count=2, essential_count=1):
    runs = HEADER + ["SERVICE DETAIL", "IN0000001", "Enhanced",
                     f"{enhanced_count} services  |  24.99 each  |  PAR-MS-ENH",
                     "CLIENT, LOCATION & SERVICE ADDRESS", "OVRC ACCOUNT", "AMOUNT"]
    runs += enhanced[0]
    # A page break inside the tier: footer, then the heading again as CONTINUED.
    runs += ["IN0000001", "Livewire, LLC", "Page 2 of 3", "SERVICE DETAIL", "IN0000001",
             "Enhanced  CONTINUED", f"{enhanced_count} services  |  24.99 each  |  PAR-MS-ENH",
             "CLIENT, LOCATION & SERVICE ADDRESS", "OVRC ACCOUNT", "AMOUNT"]
    for a in enhanced[1:]:
        runs += a
    runs += ["Enhanced subtotal", enhanced_subtotal,
             "Essential", f"{essential_count} services  |  13.99 each  |  PAR-MS-ESS",
             "CLIENT, LOCATION & SERVICE ADDRESS", "OVRC ACCOUNT", "AMOUNT"]
    for a in essential:
        runs += a
    runs += ["Essential subtotal", essential_subtotal,
             "PLATFORM AND INCLUDED SERVICES", "Platform fee", "50.00", "Invoice total", "113.97"]
    return pdf(runs)


ENHANCED = [
    account("Ada Lovelace", "Home", "12 Analytical Way, Richmond, VA, 23226",
            "Lovelace, Ada ** | Home", "24.99"),
    account("Grace Hopper", "Steakhouse on Main", "900 Main St, Midlothian, VA",
            "Hopper, Grace** | Steakhouse on", "24.99", wrap="Main"),
]
ESSENTIAL = [account("Alan Turing", "Lake House", "1 Enigma Rd, Mineral, VA, 23117",
                     "Turing, Alan *** | Lake House", "13.99")]


class HexStrings(unittest.TestCase):
    def test_hex_runs_are_read(self):
        lines = pdftext.lines(pdf(["Parasol Monitoring Services", "24.99"]), "Parasol")
        self.assertEqual(lines, ["Parasol Monitoring Services", "24.99"])

    def test_hex_inside_a_kerned_array_and_odd_digit_padding(self):
        stream = b"BT [<5061> -20 <7261736f6c>] TJ ET\nBT <41424> Tj ET\n"
        data = b"1 0 obj\n<< >>\nstream\n" + stream + b"endstream\nendobj\n"
        self.assertEqual(pdftext.lines(data, "Parasol"), ["Parasol", "AB@"])

    def test_literal_strings_still_read(self):
        data = b"1 0 obj\n<< >>\nstream\nBT (Parasol Monitoring) Tj ET\nendstream\nendobj\n"
        self.assertEqual(pdftext.lines(data, "Parasol"), ["Parasol Monitoring"])


class OnePlanInvoice(unittest.TestCase):
    def parse(self, data):
        return tabular.parse(data, "IN0000001.pdf", "parasol/invoice")

    def test_every_account_lands_with_the_old_invoices_fields(self):
        rows = self.parse(invoice(ENHANCED, ESSENTIAL))
        self.assertEqual([r["SUBSCRIBER"] for r in rows],
                         ["Lovelace, Ada", "Hopper, Grace", "Turing, Alan"])
        ada = rows[0]
        self.assertEqual((ada["LABEL"], ada["STREET"], ada["CITY_STATE_ZIP"], ada["TIER"], ada["RATE"]),
                         ("Home", "12 Analytical Way", "Richmond, VA 23226", "Enhanced", "24.99"))
        self.assertEqual(rows[2]["TIER"], "Essential")

    def test_the_key_matches_the_old_invoices_for_the_same_account(self):
        # The old invoice named the subscriber "Lovelace, Ada | Home"; the
        # OVRC line carries the same name, so the account keeps its key.
        rows = self.parse(invoice(ENHANCED, ESSENTIAL))
        self.assertEqual(rows[0]["ACCOUNT"],
                         tabular.account_key("Lovelace, Ada", "12 Analytical Way",
                                             "Richmond, VA 23226", "Home"))

    def test_a_wrapped_label_and_a_missing_zip_still_land(self):
        grace = self.parse(invoice(ENHANCED, ESSENTIAL))[1]
        self.assertEqual(grace["LABEL"], "Steakhouse on Main")
        self.assertEqual(grace["LOCATION"], "Steakhouse on Main")
        self.assertEqual((grace["STREET"], grace["CITY_STATE_ZIP"]), ("900 Main St", "Midlothian, VA"))

    def test_a_count_that_does_not_reconcile_lands_nothing(self):
        with self.assertRaisesRegex(ValueError, "Enhanced lists 3 services, parsed 2"):
            self.parse(invoice(ENHANCED, ESSENTIAL, enhanced_count=3))

    def test_a_subtotal_that_does_not_reconcile_lands_nothing(self):
        with self.assertRaisesRegex(ValueError, "Essential subtotal 27.98"):
            self.parse(invoice(ENHANCED, ESSENTIAL, essential_subtotal="27.98"))


if __name__ == "__main__":
    unittest.main()

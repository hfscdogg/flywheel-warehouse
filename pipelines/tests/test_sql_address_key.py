"""The address match key is copied into six models. Keep the copies identical.

This repo templates nothing: shared SQL is repeated verbatim with a note
naming the files to edit together. That is a deliberate trade, and the cost
is drift — six copies and no test is how one of them quietly stops agreeing
with the other five, which in a match key means the two sides of a join stop
producing the same string for the same address and the match silently fails.

Only the normalization is compared. The source column and the ZIP extraction
legitimately differ between models — one reads city_state_zip, another a
5-digit zip, another a JSON payload — but the street-name half has to be
character-for-character the same everywhere or the keys do not line up.
"""

import pathlib
import re
import unittest

SQL = pathlib.Path(__file__).resolve().parents[2] / "sql"

# From the first REGEXP_REPLACE of the chain through the non-alphanumeric
# strip: everything that turns a street line into the key's middle field.
_NORMALIZER = re.compile(
    r"REGEXP_REPLACE\(REGEXP_REPLACE\(\n\s*REGEXP_REPLACE.*?"
    r"r'\[\^a-z0-9\]\+', ''\)",
    re.S)
# The directional pass, which is the part most likely to be added to one
# model and forgotten in the others.
_DIRECTIONALS = [
    r"r'\b(n|s)(?:orth|outh)(e|w)(?:ast|est)\b', r'\1\2')",
    r"r'\b(n|s)(?:orth|outh)\b', r'\1')",
    r"r'\b(e|w)(?:ast|est)\b', r'\1')",
]


def models_with_address_key():
    return sorted(f for d in ("marts", "staging") for f in (SQL / d).glob("*.sql")
                  if "address_key" in f.read_text())


class AddressKey(unittest.TestCase):
    def setUp(self):
        self.files = models_with_address_key()
        self.assertEqual(len(self.files), 7,
                         "expected seven models to build an address key; if a "
                         "model was added or removed, update this count "
                         "deliberately rather than loosening the check")

    def normalizer(self, f):
        found = _NORMALIZER.search(f.read_text())
        self.assertIsNotNone(found, f"{f.name}: no address-key normalizer found")
        # Whitespace-normalized, because indentation differs with nesting
        # depth and that is not drift; and with the source column masked,
        # because one model reads billing_address, another a JSON payload,
        # and that difference is the whole point of having six copies.
        flat = " ".join(found.group(0).split())
        return re.sub(r"REGEXP_EXTRACT\(.*?, r'\^", "REGEXP_EXTRACT(<source>, r'^", flat)

    def test_every_copy_is_identical(self):
        first = self.files[0]
        expected = self.normalizer(first)
        for f in self.files[1:]:
            with self.subTest(model=f.name):
                self.assertEqual(
                    self.normalizer(f), expected,
                    f"{f.name} normalizes street names differently from "
                    f"{first.name}. Equal addresses must produce equal keys in "
                    f"every model or the join between them silently misses.")

    def test_directionals_are_normalized_everywhere(self):
        # "322 N 25th St" and "322 North 25th Street" are one address, and
        # keyed differently they are two. Verified against real unmatched rows.
        for f in self.files:
            with self.subTest(model=f.name):
                flat = " ".join(f.read_text().split())
                for pattern in _DIRECTIONALS:
                    self.assertIn(" ".join(pattern.split()), flat,
                                  "missing a directional normalization pass")

    def test_the_empty_key_guard_uses_the_right_constant(self):
        # The key is house|street|zip, so an empty one is "||" — two pipes.
        # Guarding on "|" excludes nothing, which is what it did until this
        # test existed: every addressless record kept its empty key, they all
        # collapsed onto one row, and a record with no address could be
        # matched to whichever customer won that collapse.
        audit = (SQL / "marts" / "kpi_subscription_audit.sql").read_text()
        self.assertNotIn("address_key != '|'", audit.replace("address_key != '||'", ""))
        self.assertGreaterEqual(audit.count("address_key != '||'"), 4)


class NameKey(unittest.TestCase):
    """The name match key is written twice and must agree, for the same
    reason the address key must agree across six models: the two sides of a
    join have to reduce the same name to the same string.

    Once on the Billing side, building billing_by_unique_name; once on the
    vendor side, in the join to it. A parenthetical dropped on one side and
    kept on the other silently matches nothing.
    """

    AUDIT = SQL / "marts" / "kpi_subscription_audit.sql"

    def name_keys(self):
        flat = " ".join(self.AUDIT.read_text().split())
        # The source column differs (display_name on one side, the vendor's
        # subscriber_name on the other) and is masked; everything after it is
        # the normalization and has to be identical.
        return re.findall(
            r"TRIM\(REGEXP_REPLACE\(REGEXP_REPLACE\(REGEXP_REPLACE\( "
            r"LOWER\(COALESCE\([\w.]+, ''\)\), (.*?' '\)\))",
            flat)

    def test_both_copies_normalize_identically(self):
        keys = self.name_keys()
        self.assertEqual(len(keys), 2,
                         "expected exactly two copies of the name key")
        self.assertEqual(keys[0], keys[1],
                         "the Billing side and the vendor side reduce names "
                         "differently, so equal names produce unequal keys")

    def test_a_name_shared_by_two_customers_is_dropped(self):
        # A name belonging to more than one Billing customer identifies
        # neither. Resolving it arbitrarily — as billing_by_name does for the
        # CRM bridge, where an address has already pinned the property — would
        # here attribute an account to a stranger on nothing but a shared name.
        # Qualified: HAVING resolves a bare name against the SELECT aliases
        # first, and ANY_VALUE(customer_id) AS customer_id shadows the column,
        # so the unqualified form is an aggregate of an aggregate and BigQuery
        # rejects the whole model.
        flat = " ".join(self.AUDIT.read_text().split())
        self.assertIn("HAVING COUNT(DISTINCT c.customer_id) = 1", flat)
        self.assertNotIn("HAVING COUNT(DISTINCT customer_id)", flat)

    def test_the_empty_name_key_never_joins(self):
        # Same shape as the address guard: an empty key would collapse every
        # unnamed customer onto one row and match every unnamed account to it.
        flat = " ".join(self.AUDIT.read_text().split())
        self.assertIn("WHERE name_key != ''", flat)
        self.assertIn("AND named.name_key != ''", flat)

    def test_the_name_match_is_ranked_last(self):
        # Address paths must win, then the contact keys, then the name.
        # Reordering this COALESCE would let a name override an address match
        # without anything failing.
        flat = " ".join(self.AUDIT.read_text().split())
        self.assertIn(
            "COALESCE(direct.customer_id, bridged.customer_id, "
            "contact.customer_id, named.customer_id)", flat)
        order = [flat.index(f"{w}.customer_id IS NOT NULL")
                 for w in ("direct", "bridged", "contact", "named")]
        self.assertEqual(order, sorted(order),
                         "match_via is decided in a different order than the "
                         "customer id is chosen")


class ContactKeyTest(unittest.TestCase):
    """Email and phone reach Billing directly, so both sides must agree."""

    AUDIT = SQL / "marts" / "kpi_subscription_audit.sql"

    def flat(self):
        return " ".join(self.AUDIT.read_text().split())

    def test_both_phone_keys_normalize_identically(self):
        # The same hazard the address key and the name key each carry a test
        # for: the Billing side and the vendor side reduce the value, and if
        # the two reductions ever drift apart, equal phone numbers produce
        # unequal keys and the tier silently matches nobody. The column name
        # differs and is masked; everything after it has to be identical.
        keys = re.findall(r"RIGHT\(REGEXP_REPLACE\([\w.]+, (.*?, 10\))",
                          self.flat())
        self.assertEqual(len(keys), 2,
                         "expected exactly two copies of the phone key")
        self.assertEqual(keys[0], keys[1],
                         "the Billing side and the vendor side reduce phone "
                         "numbers differently, so equal numbers produce "
                         "unequal keys")

    def test_an_ambiguous_contact_key_is_dropped(self):
        # An email or a phone belonging to two Billing customers identifies
        # neither, and resolving it arbitrarily would attribute an account to
        # a stranger. Both CTEs qualify the count for the same reason
        # billing_by_unique_name does -- ANY_VALUE(customer_id) AS customer_id
        # shadows the column, making the bare form an aggregate of an
        # aggregate that BigQuery rejects outright.
        flat = self.flat()
        self.assertEqual(flat.count("HAVING COUNT(DISTINCT c.customer_id) = 1"),
                         3, "billing_by_unique_name, billing_by_email and "
                            "billing_by_phone must each drop an ambiguous key")
        self.assertNotIn("HAVING COUNT(DISTINCT customer_id)", flat)

    def test_an_empty_contact_key_never_joins(self):
        # Same shape as the address and name guards. An empty email would
        # collapse every customer without one onto a single row; a phone
        # shorter than ten digits cannot identify anyone. Both are excluded
        # on the Billing side AND the vendor side, since either alone leaves
        # the empty value able to join from the other.
        flat = self.flat()
        self.assertEqual(flat.count("TRIM(COALESCE(c.email, '')) != ''"), 1)
        self.assertEqual(flat.count("TRIM(COALESCE(a.email, '')) != ''"), 1)
        self.assertEqual(flat.count(
            "REGEXP_REPLACE(COALESCE(c.phone, ''), r'[^0-9]', '')) >= 10"), 1)
        self.assertEqual(flat.count(
            "REGEXP_REPLACE(COALESCE(s.contact_phone, ''), r'[^0-9]', '')) "
            ">= 10"), 1)

    def test_one_contact_row_per_vendor_account(self):
        # Two Security Central rows can share an account number (one account,
        # two contacts) and their phones can reach two different customers.
        # Without this the account fans out into several audit rows, which
        # breaks the table's one-row-per-(vendor, account) grain.
        self.assertIn(
            "QUALIFY ROW_NUMBER() OVER ( PARTITION BY vendor, account_no "
            "ORDER BY customer_id ) = 1", self.flat())

    def test_every_path_reads_the_filtered_customer_list(self):
        # Zoho Billing's book holds internal records -- a generic "service"
        # row, staff rows marked "**TEST**" -- that are not customers. Matching
        # a vendor account to one is worse than leaving it unmatched: it
        # reports a leak, with a plausible customer name beside it, for a
        # record that was never going to hold a subscription.
        #
        # billing_customers filters them once and every path reads it, so the
        # exclusion cannot be forgotten in a tier added later. This fails if
        # any path goes back to the staging table directly -- the single
        # permitted read being billing_customers' own.
        code = [l for l in self.AUDIT.read_text().splitlines()
                if not l.lstrip().startswith("--")]
        direct = [l for l in code
                  if "staging.stg_zohobilling__customers" in l]
        self.assertEqual(len(direct), 1,
                         "a path reads the Billing customer table directly "
                         "and so skips the non-customer exclusion; read "
                         "billing_customers instead")
        self.assertEqual(
            sum("FROM billing_customers" in l for l in code), 5,
            "expected all five Billing paths -- address, name, unique name, "
            "email, phone -- to read the filtered list")

    def test_the_exclusion_is_narrow(self):
        # A too-broad rule silently drops real customers, which is the failure
        # this table cannot show you: the account just goes unmatched. The
        # marker rule keys on "**", which no real name contains. The name rule
        # is an exact match, never a substring, so "Service Plus LLC" stays.
        flat = self.flat()
        self.assertIn(
            r"NOT REGEXP_CONTAINS(COALESCE(display_name, ''), r'\*\*')", flat)
        self.assertIn(
            "LOWER(TRIM(COALESCE(display_name, ''))) NOT IN ('service')", flat)
        self.assertNotIn("LIKE '%service%'", flat)
        self.assertNotIn("REGEXP_CONTAINS(display_name, r'service')", flat)

    def test_the_contact_join_is_keyed_on_vendor_too(self):
        # account_no is only unique within a vendor. Joining on it alone would
        # let a Security Central account number collide with an Alarm.com
        # customer id and match one vendor's account to the other's customer.
        self.assertIn(
            "ON contact.vendor = v.vendor AND contact.account_no = "
            "v.account_no", self.flat())


if __name__ == "__main__":
    unittest.main()

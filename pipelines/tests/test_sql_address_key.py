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
        #
        # Three copies since the QuickBooks path landed: the Billing side, the
        # vendor side (extracted once in vendor_contact and read by both
        # consumers), and the QuickBooks side. All three must agree — the
        # vendor copy is joined against BOTH book copies, so a drift in any
        # one of them breaks a tier.
        keys = re.findall(r"RIGHT\(REGEXP_REPLACE\([\w.]+, (.*?, 10\))",
                          self.flat())
        self.assertEqual(len(keys), 3,
                         "expected exactly three copies of the phone key")
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
                         7, "billing_by_unique_name, billing_by_email and "
                            "billing_by_phone, plus the four QuickBooks tiers "
                            "(address, email, phone, name), must each drop an "
                            "ambiguous key")
        self.assertNotIn("HAVING COUNT(DISTINCT customer_id)", flat)

    def test_an_empty_contact_key_never_joins(self):
        # Same shape as the address and name guards. An empty email would
        # collapse every customer without one onto a single row; a phone
        # shorter than ten digits cannot identify anyone. Both are excluded
        # on the Billing side AND the vendor side, since either alone leaves
        # the empty value able to join from the other.
        #
        # Two book-side copies of each since the QuickBooks path landed (Zoho
        # Billing and QuickBooks), and still exactly one vendor-side copy of
        # each: vendor_contact extracts the account's email and phone once and
        # both consumers read it, so the vendor-side guard cannot be dropped
        # for one consumer and kept for the other.
        flat = self.flat()
        self.assertEqual(flat.count("TRIM(COALESCE(c.email, '')) != ''"), 2)
        self.assertEqual(flat.count("TRIM(COALESCE(a.email, '')) != ''"), 1)
        self.assertEqual(flat.count(
            "REGEXP_REPLACE(COALESCE(c.phone, ''), r'[^0-9]', '')) >= 10"), 2)
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


class QboCustomerPathTest(unittest.TestCase):
    """The QuickBooks evidence path must stay INDEPENDENT of the Billing match.

    Zoho Billing is not the whole picture — check payers reach QuickBooks and
    never reach Billing — so the audit resolves each vendor account to a
    QuickBooks customer as well, and reports whether that customer has been
    invoiced for monitoring. Roughly half the leak list is explained by it.

    The hazard this class guards is the shortcut: nothing links a QuickBooks
    customer to a Zoho Billing one, so it is tempting to hop from the Billing
    customer this mart already matched to a QuickBooks customer by name. That
    stacks a second name match on top of whatever key found the Billing
    customer, and the combined claim is weaker than either half — including on
    the OK rows, where the damage cannot be seen. The QuickBooks path must
    start from the vendor account's own keys, every time.
    """

    AUDIT = SQL / "marts" / "kpi_subscription_audit.sql"

    def code(self):
        return [l for l in self.AUDIT.read_text().splitlines()
                if not l.lstrip().startswith("--")]

    def flat(self):
        return " ".join(self.AUDIT.read_text().split())

    def test_every_path_reads_the_one_customer_list(self):
        # The analogue of the billing_customers guard. Two independent things
        # read the QuickBooks customer book — the Billing bridge and the
        # QuickBooks evidence path — and both must read the single CTE, so
        # that a filter added to it later cannot be silently skipped by one.
        # Exact equality, like the Billing counts: a new path that reads the
        # staging table directly fails here until someone updates this
        # deliberately.
        code = self.code()
        self.assertEqual(
            sum("staging.stg_qbo__customers" in l for l in code), 1,
            "a path reads the QuickBooks customer table directly instead of "
            "the qbo_customers CTE")
        self.assertEqual(
            sum("FROM qbo_customers" in l for l in code), 5,
            "expected all five QuickBooks reads — the Billing bridge plus the "
            "four match tiers (address, email, phone, name) — to read the CTE")

    def test_the_qbo_path_is_not_bridged_through_billing(self):
        # customer_by_qbo must resolve from the vendor account's own keys. If
        # it ever references the Billing match — billing_by_name, or the
        # matched customer_id — the two answers stop being independent and the
        # column stops meaning what its description says it means.
        flat = self.flat()
        start = flat.index("customer_by_qbo AS (")
        body = flat[start:flat.index("qbo_monitoring AS (", start)]
        for forbidden in ("billing_by_name", "billing_by_unique_name",
                          "billing_customers", "billing_by_email",
                          "billing_by_phone", "customer_by_address",
                          "customer_by_contact"):
            self.assertNotIn(
                forbidden, body,
                f"customer_by_qbo reads {forbidden}, so the QuickBooks match "
                f"is bridged through the Billing one instead of resolved "
                f"independently")

    def test_both_qbo_name_keys_normalize_identically(self):
        # Same hazard as the Billing name key, and one extra pass: the vendors
        # write "Tilghman, Richard" where QuickBooks writes "Richard
        # Tilghman", so this key inverts on the first comma. Written on the
        # book side and the vendor side; they must agree or the tier — which
        # reaches more leak rows than the other three combined — silently
        # matches nobody.
        keys = re.findall(
            r"TRIM\(REGEXP_REPLACE\(REGEXP_REPLACE\(REGEXP_REPLACE\("
            r"REGEXP_REPLACE\( LOWER\(COALESCE\([\w.]+, ''\)\), (.*?' '\)\))",
            self.flat())
        self.assertEqual(len(keys), 2,
                         "expected exactly two copies of the QuickBooks name key")
        self.assertEqual(keys[0], keys[1],
                         "the QuickBooks side and the vendor side reduce names "
                         "differently, so equal names produce unequal keys")
        self.assertIn(r"r'^\s*([^,]+?)\s*,\s*(.+)$', r'\2 \1'", keys[0],
                      "the comma inversion is missing; without it Parasol's "
                      "'Last, First' names reach almost nothing")

    def test_the_qbo_name_match_is_ranked_last(self):
        # Address, then the contact keys, then the name — the same ranking the
        # Billing match uses, for the same reason: a shared name is not
        # evidence two records are the same household.
        flat = self.flat()
        self.assertIn(
            "COALESCE(a.customer_id, e.customer_id, p.customer_id, "
            "n.customer_id)", flat)
        start = flat.index("customer_by_qbo AS (")
        body = flat[start:flat.index("qbo_monitoring AS (", start)]
        order = [body.index(f"{w}.customer_id IS NOT NULL")
                 for w in ("a", "e", "p", "n")]
        self.assertEqual(order, sorted(order),
                         "qbo_match_via is decided in a different order than "
                         "the customer id is chosen")

    def test_the_empty_qbo_name_key_never_joins(self):
        # Same shape as every other empty-key guard in this file. Excluded on
        # the book side and on the vendor side, since either alone leaves the
        # empty value able to join from the other.
        flat = self.flat()
        self.assertIn("WHERE qbo_name_key != ''", flat)
        self.assertIn("AND n.match_key != ''", flat)

    def test_monitoring_is_identified_by_income_account(self):
        # Which item is monitoring is a bookkeeping fact. Matching on item
        # names instead would miss LWS-APPCONTROL and INV-FULL-ANN, which do
        # not say "monitoring", and catch items that are not.
        flat = self.flat()
        for account in ("'Security Monitoring Income'",
                        "'Invision Monitoring Income'",
                        "'Security Discounts'"):
            self.assertIn(account, flat)
        self.assertIn("income_account_name IN (", flat)
        self.assertNotIn("item_name LIKE", flat)

    def test_a_voided_invoice_is_not_revenue(self):
        # QuickBooks keeps a void as a zero-amount invoice with its lines
        # intact, so a naive filter reads one as evidence the customer is
        # paying — the exact opposite of what it means, and in the direction
        # that keeps a real leak off the list.
        self.assertIn("AND i.total_amount > 0", self.flat())

    def test_the_finding_gate_still_asks_billing_only(self):
        # This change is ADDITIVE. The QuickBooks columns are advisory and the
        # `finding` CASE must not consider them, so that every existing row
        # keeps the finding it had and the two answers can be compared on real
        # data before one is allowed to override the other. Folding
        # qbo_monitoring_revenue into the revenue gate is a separate, later
        # change — and when it is made, this test is the one to update.
        flat = self.flat()
        start = flat.index("WHEN NOT COALESCE(v.is_active_at_vendor, FALSE)")
        gate = flat[start:flat.index("END AS finding", start)]
        for forbidden in ("qbo_", "qm."):
            self.assertNotIn(
                forbidden, gate,
                "the finding CASE reads a QuickBooks column; this change is "
                "additive and the gate must still ask Zoho Billing alone")
        self.assertIn("COALESCE(s.active_subscriptions, 0) = 0 THEN "
                      "'BILLED_NO_SUBSCRIPTION'", gate)


class DirectBilledPathTest(unittest.TestCase):
    """The direct-payer marker must be read once, where it is already grouped.

    Security Central bills a few customers itself instead of billing Livewire,
    and prints how each pays. Those customers are paying for monitoring — just
    not to us and not through Zoho Billing — so they are not a leak, and
    nothing else in the warehouse says so. This is the exclusion list the mart
    spent months asking for.

    The hazard is the shape of the feed. It carries ONE ROW PER RESOURCE LINE,
    several per account, so a second read joined back on account_no fans the
    mart out: the count of BILLED_NO_SUBSCRIPTION rows rises, and every SUM
    over vendor_monthly_cost rises with it, silently and in the direction that
    looks like a worse leak. The first query written against this column hit
    exactly that and turned 230 rows into 238. The one read must stay in
    sc_billing, which is already reduced to one row per account.
    """

    AUDIT = SQL / "marts" / "kpi_subscription_audit.sql"

    def code(self):
        return [l for l in self.AUDIT.read_text().splitlines()
                if not l.lstrip().startswith("--")]

    def flat(self):
        return " ".join(self.AUDIT.read_text().split())

    def test_the_recurring_feed_is_read_exactly_once(self):
        # Exact equality, like the billing_customers and qbo_customers counts
        # above: a second read of a per-line feed is the fan-out, so a new one
        # fails here until someone adds it deliberately and proves it groups.
        self.assertEqual(
            sum("staging.stg_vendor__securitycentral_recurring" in l
                for l in self.code()), 1,
            "the per-line Security Central billing feed is read more than "
            "once; a second read joined on account_no fans the mart out")

    def test_the_marker_is_derived_where_the_feed_is_grouped(self):
        # Inside sc_billing, which is GROUP BY account_no — that is what makes
        # one row per account, and what makes the flag safe to join on.
        flat = self.flat()
        start = flat.index("sc_billing AS (")
        body = flat[start:flat.index("securitycentral AS (", start)]
        self.assertIn("LOGICAL_OR(payment_method IS NOT NULL) AS direct_billed",
                      body,
                      "direct_billed is not derived inside sc_billing")
        self.assertIn("GROUP BY account_no", body)

    def test_the_marker_is_not_dropped_by_the_cost_guard(self):
        # vendor_monthly_cost is deliberately put on ONE row per account so a
        # SUM cannot double-count it. A property of the account must NOT be,
        # or a filter on it drops the row the cost is not on.
        flat = self.flat()
        start = flat.index("securitycentral AS (")
        body = flat[start:flat.index("FROM sc_identity i", start)]
        guarded = body[body.index("ROW_NUMBER() OVER ("):]
        self.assertIn("COALESCE(b.direct_billed, FALSE) AS direct_billed",
                      " ".join(body.split()))
        self.assertNotIn(
            "direct_billed", guarded[:guarded.index("AS vendor_monthly_cost")],
            "direct_billed is inside the ROW_NUMBER guard that exists to stop "
            "a COST being counted twice; an account property belongs on every "
            "row of the account")

    def test_every_vendor_branch_carries_the_column(self):
        # A UNION ALL branch that omits it does not fail in BigQuery — it
        # shifts the columns and the union takes the next one by position.
        self.assertEqual(
            sum("direct_billed" in l for l in self.code()
                if "AS direct_billed" in l or l.strip() == "direct_billed,"),
            4,
            "expected the derivation, the carry-through and one entry per "
            "vendor branch of the accounts union")

    def test_the_column_is_never_null(self):
        # The obvious use is `WHERE NOT direct_billed`, and a NULL would drop
        # every Alarm.com and Parasol row from that filter without a word.
        flat = self.flat()
        self.assertIn("COALESCE(b.direct_billed, FALSE)", flat)
        self.assertEqual(flat.count("FALSE AS direct_billed"), 2,
                         "the two vendors with no direct-billing arrangement "
                         "must read FALSE, not NULL")

    def test_the_finding_gate_does_not_read_it(self):
        # Additive, exactly like the QuickBooks columns. When direct_billed is
        # folded into the revenue gate, this test is one of the two to update.
        flat = self.flat()
        start = flat.index("WHEN NOT COALESCE(v.is_active_at_vendor, FALSE)")
        gate = flat[start:flat.index("END AS finding", start)]
        self.assertNotIn(
            "direct_billed", gate,
            "the finding CASE reads direct_billed; this change is additive "
            "and the gate must still ask Zoho Billing alone")


if __name__ == "__main__":
    unittest.main()

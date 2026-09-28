"""An address match whose name disagrees yields to the account's own email or phone.

An address names a property, not a household. On the 2026-09-28 build 12 of
the 45 leak accounts had matched, by address, a Billing customer whose name
shares no word with the subscriber's -- Thomas Leonard at 3630 John Latane
Ln matched Richard Turner -- while the account's own phone and email reached
Patricia & Allen Leonard, who are subscribed.

The rule in kpi_subscription_audit's `matched` CTE is narrow on purpose, and
each half of it was measured:

- It fires only where an ADDRESS path won. The email/phone and name tiers
  already rank below it; letting the check touch them would re-rank matches
  that were never an address guess.
- It fires only where the address customer's name shares NO word with the
  subscriber's. Agreement keeps the address match, however many other paths
  exist.
- It moves only to the email/phone customer, and only where THAT name
  agrees. The name tier was tried too and rejected: it moved businesses whose
  vendor record names the contact person ("Walker, Kayla" at Downtown Pups)
  onto personal profiles, and turned one OK account into a false leak.
- The comparison is the one name_overlaps makes, so the column still
  describes the customer the account ended on.
"""

import pathlib
import re
import unittest

AUDIT = pathlib.Path(__file__).resolve().parents[2] / "sql" / "marts" / "kpi_subscription_audit.sql"


def code_flat():
    lines = [l for l in AUDIT.read_text().splitlines() if not l.lstrip().startswith("--")]
    return " ".join(" ".join(lines).split())


def cte(name, following):
    m = re.search(rf"\b{name} AS \((.*?)\), {following} AS \(", code_flat())
    if m is None:
        raise AssertionError(f"{name} (followed by {following}) is gone")
    return m.group(1)


def matched_body():
    flat = code_flat()
    start = flat.index("matched AS (")
    end = flat.index(" SELECT v.vendor,", start)
    return flat[start:end]


def takes_contact():
    body = matched_body()
    m = re.search(r"COALESCE\((.*?), FALSE\) AS takes_contact", body)
    if m is None:
        raise AssertionError("takes_contact is gone from matched")
    return m.group(1)


# The subscriber-name split name_overlaps performs, and the word-length floor.
_SPLIT = ("UNNEST(SPLIT(LOWER(REGEXP_REPLACE( COALESCE(v.subscriber_name, ''), "
          "r'[^a-zA-Z ]', '')), ' ')) AS t")


class AddressYieldsToContact(unittest.TestCase):

    def test_only_an_address_win_is_second_guessed(self):
        self.assertIn(
            "COALESCE(direct.customer_id, bridged.customer_id) IS NOT NULL AS ranked_by_address",
            cte("matched_candidates", "matched"))
        self.assertTrue(takes_contact().startswith("mc.ranked_by_address AND "),
                        "the override must require that an address path won")

    def test_an_agreeing_address_match_is_kept(self):
        self.assertIn(
            "AND NOT EXISTS (SELECT 1 FROM UNNEST(mc.name_words) AS w "
            "WHERE STRPOS(LOWER(mc.ranked_display_name), w) > 0)",
            takes_contact())

    def test_it_moves_only_to_an_agreeing_email_or_phone_customer(self):
        self.assertIn(
            "AND EXISTS (SELECT 1 FROM UNNEST(mc.name_words) AS w "
            "WHERE STRPOS(LOWER(mc.contact_display_name), w) > 0)",
            takes_contact())

    def test_the_name_tier_never_overrides_an_address(self):
        body = matched_body()
        for word in ("named", "inverted"):
            self.assertNotIn(word, body, f"matched must not read the {word} name match")
        self.assertNotIn("named_customer_id", cte("matched_candidates", "matched"))

    def test_the_words_are_the_ones_name_overlaps_reads(self):
        candidates = cte("matched_candidates", "matched")
        self.assertIn(f"ARRAY(SELECT t FROM {_SPLIT} WHERE LENGTH(t) >= 3) AS name_words",
                      candidates)
        flat = code_flat()
        overlaps = flat[flat.index("SELECT LOGICAL_OR(LENGTH(t) >= 3 AND STRPOS(LOWER(v.display_name), t) > 0)"):]
        self.assertTrue(overlaps.split(" FROM ", 1)[1].startswith(_SPLIT),
                        "name_overlaps and name_words must split the name identically")

    def test_customer_name_and_path_move_together(self):
        body = matched_body()
        for col, contact, ranked in (
                ("customer_id", "contact_customer_id", "ranked_customer_id"),
                ("display_name", "contact_display_name", "ranked_display_name"),
                ("match_via", "contact_match_via", "ranked_match_via")):
            self.assertIn(f"IF(c.takes_contact, c.{contact}, c.{ranked}) AS {col}", body)

    def test_the_working_columns_do_not_reach_the_mart(self):
        body = matched_body()
        m = re.search(r"c\.\* EXCEPT \((.*?)\)", body)
        self.assertIsNotNone(m)
        dropped = {c.strip() for c in m.group(1).split(",")}
        self.assertEqual(dropped, {
            "ranked_customer_id", "ranked_display_name", "ranked_match_via",
            "ranked_by_address", "contact_customer_id", "contact_display_name",
            "contact_match_via", "name_words", "takes_contact"})

    def test_the_mart_reads_the_overridden_match(self):
        self.assertIn("FROM matched v LEFT JOIN subs s ON s.customer_id = v.customer_id",
                      code_flat())


if __name__ == "__main__":
    unittest.main()

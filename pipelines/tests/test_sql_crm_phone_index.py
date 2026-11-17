"""kpi_crm_phone_index's match key — stdlib only.

The kitchen hashes each CallRail caller's number and looks the key up in this
mart. If the SQL's normalisation or salt drifts from the kitchen's
(flywheel-kitchen kitchen/sources/crm_match.py), nothing matches and the
brief silently reports every caller as unknown. These tests pin the exact
expressions and give the reference vectors the kitchen's own tests repeat.
"""

import hashlib
import pathlib
import re
import unittest

SQL = (pathlib.Path(__file__).resolve().parents[2] / "sql" / "marts" / "kpi_crm_phone_index.sql").read_text()

EXT = r"(?i)\s*(x|ext\.?|extension|#)\s*\d+\s*$"
NANP = r"^[2-9][0-9]{2}[2-9][0-9]{6}$"
SALT = "flywheel-phone:"


def phone_key(raw):
    """Python mirror of the SQL: the reference the kitchen must agree with."""
    d0 = re.sub(r"\D", "", re.sub(EXT, "", raw or ""))
    d10 = d0[1:] if len(d0) == 11 and d0.startswith("1") else d0
    if not re.match(NANP, d10):
        return None
    return hashlib.sha256((SALT + d10).encode()).hexdigest()


# Shared with the kitchen's tests: same inputs, same keys.
VECTORS = {
    "(804) 555-0142": "8045550142",
    "+1 804-555-0142": "8045550142",
    "804.555.0142 x204": "8045550142",
    "804-555-0142 ext. 9": "8045550142",
    "18045550142": "8045550142",
}


class PhoneKey(unittest.TestCase):
    def test_the_sql_uses_the_pinned_expressions(self):
        self.assertIn(f"r'{EXT}'", SQL)
        self.assertIn(f"r'{NANP}'", SQL)
        self.assertIn(f"TO_HEX(SHA256(CONCAT('{SALT}', d10)))", SQL)
        self.assertIn("IF(LENGTH(d0) = 11 AND STARTS_WITH(d0, '1'), SUBSTR(d0, 2), d0)", SQL)

    def test_formats_of_one_number_share_one_key(self):
        want = hashlib.sha256((SALT + "8045550142").encode()).hexdigest()
        for raw in VECTORS:
            self.assertEqual(phone_key(raw), want, raw)

    def test_junk_gets_no_key(self):
        for raw in ("", None, "555-0142", "+44 20 7946 0958", "0045550142", "8041550142"):
            self.assertIsNone(phone_key(raw), raw)

    def test_a_record_with_no_deals_has_none(self):
        # A LEFT JOIN miss is a STRUCT of NULLs, which IGNORE NULLS keeps;
        # it must be turned into a NULL first or every lead "has a deal".
        self.assertIn("ARRAY_AGG(IF(dl.deal_id IS NULL, NULL,", SQL)
        self.assertIn("COALESCE(rd.deals, []) AS deals", SQL)

    def test_leads_never_carry_deals(self):
        self.assertIn("ON k.record_type != 'lead'", SQL)

    def test_test_deals_are_excluded(self):
        self.assertIn("WHERE NOT COALESCE(is_test_record, FALSE)", SQL)


if __name__ == "__main__":
    unittest.main()

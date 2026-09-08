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
        self.assertEqual(len(self.files), 6,
                         "expected six models to build an address key; if a "
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


if __name__ == "__main__":
    unittest.main()

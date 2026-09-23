"""Every goal card points at a mart that exists and columns that exist.

A goal card tells a Hermes engine which number it is accountable to and
how to read it. It is plain YAML beside the SQL, so nothing stops a mart
column being renamed out from under it: the card keeps its old query, the
agent runs it, and the error or the wrong answer surfaces in a report to the
owner rather than here. This test reads the cards the way the agent would
and checks them against the mart SQL.

CI installs nothing, so the YAML is read with regexes over the few top-level
keys the card schema fixes (goal-cards/README.md), not with a YAML library.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CARDS = ROOT / "goal-cards"
MARTS = ROOT / "sql" / "marts"

REQUIRED = ("kpi", "title", "status", "owner", "cadence", "mart_table",
            "credential", "definition", "query", "columns", "baseline",
            "target", "rules")


def cards():
    return sorted(CARDS.glob("*/*.yaml"))


def top_level(text, key):
    """The value on a top-level `key:` line, comment stripped."""
    found = re.search(rf"^{key}:[ \t]*(.*)$", text, re.M)
    return None if found is None else re.sub(r"\s+#.*$", "", found.group(1)).strip()


def block(text, key):
    """The indented lines under a top-level `key: |` or `key: >`."""
    found = re.search(rf"^{key}:[^\n]*\n((?:[ \t]+[^\n]*\n|\n)+)", text, re.M)
    return "" if found is None else found.group(1)


class GoalCards(unittest.TestCase):
    def test_there_are_cards(self):
        self.assertGreaterEqual(len(cards()), 3)

    def test_every_card_carries_the_schema(self):
        for card in cards():
            text = card.read_text()
            for key in REQUIRED:
                with self.subTest(card=card.name, key=key):
                    self.assertIsNotNone(top_level(text, key), f"missing {key}:")

    def test_the_kpi_matches_the_file_name(self):
        for card in cards():
            with self.subTest(card=card.name):
                self.assertEqual(top_level(card.read_text(), "kpi"), card.stem)

    def test_the_mart_exists(self):
        for card in cards():
            with self.subTest(card=card.name):
                table = top_level(card.read_text(), "mart_table")
                name = table.rsplit(".", 1)[-1]
                self.assertTrue(table.endswith(f".marts.{name}"),
                                "a card reads a mart, never raw or staging")
                self.assertTrue((MARTS / f"{name}.sql").exists(), f"no mart {name}")

    def test_the_query_reads_the_cards_own_mart(self):
        # The agent's credential reaches marts; a card whose canonical query
        # reads anything else fails in the agent's seat, not here.
        for card in cards():
            text = card.read_text()
            name = top_level(text, "mart_table").rsplit(".", 1)[-1]
            with self.subTest(card=card.name):
                sources = re.findall(r"\b(?:FROM|JOIN)\s+([\w.]+)", block(text, "query"))
                self.assertEqual(set(sources), {f"marts.{name}"})

    def test_every_listed_column_is_a_described_mart_column(self):
        # The mart declares every output column with an ALTER COLUMN, and
        # test_sql_marts_described keeps that list complete; so a card column
        # missing from it has been renamed or dropped.
        for card in cards():
            text = card.read_text()
            name = top_level(text, "mart_table").rsplit(".", 1)[-1]
            declared = set(re.findall(
                rf"^ALTER TABLE marts\.{name} ALTER COLUMN (\w+)$",
                (MARTS / f"{name}.sql").read_text(), re.M))
            listed = re.findall(r"\w+", top_level(text, "columns"))
            query = block(text, "query")
            for column in listed:
                with self.subTest(card=card.name, column=column):
                    self.assertIn(column, declared, f"marts.{name} has no {column}")
                    self.assertRegex(query, rf"\b{column}\b",
                                     "listed but not read by the query")

    def test_a_card_without_a_target_is_a_draft(self):
        # An engine accountable to "null" is accountable to nothing. A target
        # is the owner's to set; until then the card must say it is a draft.
        for card in cards():
            text = card.read_text()
            with self.subTest(card=card.name):
                if top_level(text, "target") in ("null", "~", ""):
                    self.assertEqual(top_level(text, "status"), "draft")
                else:
                    self.assertEqual(top_level(text, "status"), "active")

    def test_every_card_has_an_owner(self):
        for card in cards():
            with self.subTest(card=card.name):
                self.assertRegex(top_level(card.read_text(), "owner"), r"^[\w.+-]+@[\w.-]+$")


if __name__ == "__main__":
    unittest.main()

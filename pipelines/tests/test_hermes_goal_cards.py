"""The agent endpoint serves the goal cards, and the deploy ships them.

Two halves have to hold together. hermes-mcp/goal_cards.py reads the cards
from goal_cards/ beside server.py; scripts/07-hermes-endpoint.sh puts them
there, because `gcloud run deploy --source` uploads one directory and the
cards live outside it in goal-cards/<client>/. Break either half and the
tools still answer, with an empty list, and nothing else notices.

goal_cards.py is standard-library only for exactly this reason: CI installs
nothing, so server.py (mcp, BigQuery) cannot be imported here, but the card
logic can.
"""
import importlib.util
import os
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SERVER = ROOT / "hermes-mcp" / "server.py"
SCRIPT = ROOT / "scripts" / "07-hermes-endpoint.sh"
LIVEWIRE = ROOT / "goal-cards" / "livewire"

_spec = importlib.util.spec_from_file_location(
    "goal_cards", ROOT / "hermes-mcp" / "goal_cards.py")
goal_cards = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(goal_cards)


class ServesTheCards(unittest.TestCase):
    def test_every_card_is_listed_with_its_target(self):
        listed = goal_cards.list_cards(LIVEWIRE)
        self.assertEqual([c["kpi"] for c in listed],
                         sorted(p.stem for p in LIVEWIRE.glob("*.yaml")))
        for card in listed:
            with self.subTest(kpi=card["kpi"]):
                for key in goal_cards.SUMMARY_KEYS:
                    self.assertTrue(card[key], f"{key} empty in the listing")

    def test_a_card_is_served_verbatim(self):
        # The rules are prose written for a reader; a parse that dropped or
        # reflowed one would change what the agent is told.
        for path in LIVEWIRE.glob("*.yaml"):
            with self.subTest(kpi=path.stem):
                self.assertEqual(goal_cards.get_card(path.stem, LIVEWIRE),
                                 {"kpi": path.stem, "card": path.read_text()})

    def test_a_kpi_cannot_walk_out_of_the_directory(self):
        # A real .yaml one level up, so a missing name check would find it:
        # without the file, "../outside" fails as not-found and the test
        # would pass over a server that had no check at all.
        with tempfile.TemporaryDirectory() as root:
            cards = pathlib.Path(root) / "goal_cards"
            cards.mkdir()
            (cards / "inside.yaml").write_text("kpi: inside\n")
            (pathlib.Path(root) / "outside.yaml").write_text("secret\n")
            self.assertEqual(goal_cards.get_card("inside", cards)["kpi"], "inside")
            for bad in ("../outside", "..", "/etc/passwd", "inside.yaml",
                        "Inside", "", None):
                with self.subTest(kpi=bad):
                    with self.assertRaises(ValueError):
                        goal_cards.get_card(bad, cards)

    def test_an_unknown_kpi_names_the_cards_that_exist(self):
        with self.assertRaises(ValueError) as caught:
            goal_cards.get_card("win_rate", LIVEWIRE)
        self.assertIn("subscription_leak", str(caught.exception))

    def test_no_cards_directory_serves_none_rather_than_failing(self):
        # A revision deployed before cards shipped has no goal_cards/.
        with tempfile.TemporaryDirectory() as empty:
            missing = pathlib.Path(empty) / "goal_cards"
            self.assertEqual(goal_cards.list_cards(missing), [])
            with self.assertRaises(ValueError):
                goal_cards.get_card("subscription_leak", missing)

    def test_the_server_exposes_both_tools(self):
        src = SERVER.read_text()
        for tool, call in (("list_goal_cards", "goal_cards.list_cards("),
                           ("get_goal_card", "goal_cards.get_card(")):
            with self.subTest(tool=tool):
                self.assertRegex(src, rf"@mcp\.tool\(\)\ndef {tool}\(")
                self.assertIn(call, src)


class DeployShipsTheCards(unittest.TestCase):
    def dry_run(self):
        env = dict(os.environ, DRY_RUN="1")
        done = subprocess.run(["bash", str(SCRIPT), "livewire", "redeploy"],
                              capture_output=True, text=True, env=env, cwd=ROOT)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return done.stdout + done.stderr

    def test_the_build_source_is_a_staging_copy_carrying_the_cards(self):
        out = self.dry_run()
        shipped = re.search(r"goal cards shipped: (\d+) from goal-cards/livewire/", out)
        self.assertIsNotNone(shipped, out)
        self.assertEqual(int(shipped.group(1)), len(list(LIVEWIRE.glob("*.yaml"))))
        source = re.search(r"--source (\S+)", out).group(1)
        self.assertNotEqual(pathlib.Path(source).name, "hermes-mcp",
                            "uploading hermes-mcp/ directly ships no cards")
        # The staging copy is removed when the script exits.
        self.assertFalse(pathlib.Path(source).exists())

    def test_the_staging_copy_takes_the_whole_server(self):
        code = "\n".join(l for l in SCRIPT.read_text().splitlines()
                         if not l.lstrip().startswith("#"))
        self.assertIn('cp -R "$REPO_ROOT/hermes-mcp/." "$BUILD_DIR/"', code)
        self.assertIn('"$REPO_ROOT/goal-cards/$CLIENT_SLUG"', code)
        self.assertIn("trap cleanup_build_dir EXIT", code)


if __name__ == "__main__":
    unittest.main()

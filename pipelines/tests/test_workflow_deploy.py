"""The endpoint deploy workflow must stay narrow, gated, and non-bootstrapping.

Shipping a revision of hermes-mcp changes what every connected agent can see:
DATASETS_AGENT decides which datasets the endpoint LISTS, and a stale value is
exactly the failure that motivated this workflow — a deployed revision served
`marts` while client.env had said `marts staging` for weeks, so the agent
reported staging did not exist.

Three properties make automating that safe, and each of them reads as a
detail someone could "tidy up" without realising what it was holding:

  environment:              the approval gate. Remove it and a dispatch ships
                            with no human in the loop.
  WIF_DEPLOYER_SERVICE_ACCOUNT  the narrow identity. Swap it for the ingest
                            one and CI gains dataEditor on every dataset.
  redeploy, not deploy      `deploy` converges project IAM and creates
                            secrets; `redeploy` does neither.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEPLOY = ROOT / ".github" / "workflows" / "deploy-endpoint.yml"
SCRIPT = ROOT / "scripts" / "07-hermes-endpoint.sh"


class DeployWorkflow(unittest.TestCase):
    def src(self):
        return DEPLOY.read_text()

    def test_it_is_gated_on_an_environment(self):
        # Reviewers on the environment must approve before ANY step runs,
        # including the WIF exchange — so an unapproved dispatch never holds
        # a deploy credential.
        # re.M matters: without it `^` anchors to the start of the whole
        # file and the assertion can only ever fail.
        self.assertTrue(
            re.search(r"^\s*environment:\s*\S+", self.src(), re.M),
            "the deploy job has no environment: gate")

    def test_it_uses_the_narrow_deployer_identity(self):
        # ingest-writer holds dataEditor on every dataset. If this workflow
        # ever authenticates as it, a job that exists to ship a container can
        # also rewrite the warehouse.
        src = self.src()
        self.assertIn("${{ vars.WIF_DEPLOYER_SERVICE_ACCOUNT }}", src)
        self.assertNotIn("${{ vars.WIF_SERVICE_ACCOUNT }}", src,
                         "the deploy workflow authenticates as the ingest "
                         "service account; use the endpoint-deployer one")

    def test_it_redeploys_and_never_bootstraps(self):
        src = self.src()
        self.assertIn("redeploy", src)
        self.assertNotRegex(
            src, r"07-hermes-endpoint\.sh\s+\"?\$?\{?[A-Za-z_]*\}?\"?\s+deploy\b",
            "the workflow invokes the bootstrapping `deploy` action, which "
            "converges project IAM and creates the token secret")

    def test_no_dispatch_input_is_interpolated_into_a_run_script(self):
        # Same hazard probe.yml carries a test for, and worse here: this job
        # holds a credential that can deploy. `reason` is free text.
        for block in re.findall(r"^\s*run: \|\n((?:\s{8,}.*\n|\n)+)", self.src(), re.M):
            found = re.findall(r"\$\{\{[^}]*\}\}", block)
            self.assertEqual(found, [],
                             f"a run: block interpolates {found}; bind it to an "
                             f"env var and read it as \"$VAR\"")

    def test_it_verifies_the_live_revision_afterwards(self):
        # A successful deploy says nothing about whether the revision serves
        # the right datasets. That was the original bug, and it was invisible
        # from the deploy's own exit code.
        src = self.src()
        self.assertIn("DATASETS_AGENT", src)
        self.assertIn("gcloud run services describe", src)


class RedeployAction(unittest.TestCase):
    """`redeploy` must do the deploy and nothing else."""

    def body(self):
        src = SCRIPT.read_text()
        start = src.index("\n  redeploy)")
        return src[start:src.index("\n  rotate-token)", start)]

    def code(self):
        return [l for l in self.body().splitlines()
                if not l.lstrip().startswith("#")]

    def test_it_grants_nothing_and_creates_nothing(self):
        # The premise of the narrow deployer account: redeploy needs no
        # Secret Manager, no project IAM, no service enablement. If it grows
        # any of them, the account's grants no longer cover it AND the account
        # would have to be widened to match — so fail here first.
        forbidden = ("add-iam-policy-binding", "secrets create",
                     "services enable", "secrets versions add",
                     "mint_token_version")
        code = "\n".join(self.code())
        for needle in forbidden:
            self.assertNotIn(needle, code,
                             f"redeploy runs `{needle}`, which the "
                             f"endpoint-deployer account is deliberately not "
                             f"permitted to do")

    def test_it_refuses_to_bootstrap(self):
        # Without these checks a first-ever deploy attempted from CI fails
        # deep inside gcloud with a permission error that reads like a broken
        # pipeline rather than "this was never meant to run here".
        code = "\n".join(self.code())
        self.assertIn("secrets describe", code)
        self.assertIn("run services describe", code)
        self.assertIn("die ", code)

    def test_env_vars_survive_a_comma_in_a_value(self):
        # The bug this test exists for shipped on 2026-09-04 and was not
        # noticed until 2026-09-16. AGENT_SCOPE=wide makes DATASETS_AGENT
        # "marts staging", which this script joins to "marts,staging".
        # --set-env-vars splits PAIRS on a comma, so that value ends the pair
        # early and leaves a bare "staging" with no '=' — gcloud rejects the
        # whole invocation.
        #
        # The failure is silent in the way that matters: the script exits
        # non-zero, no revision is created, and the OLD revision keeps serving
        # perfectly well. Nothing is down. The only symptom is an endpoint
        # answering from code that predates the variable, which showed up as
        # agents being told staging did not exist.
        #
        # ^@^ is gcloud's documented escape: it makes '@' the pair separator,
        # so commas inside values are ordinary characters. A narrow-scope
        # client has no comma and would pass either way, which is exactly why
        # this needs a test rather than a working deploy as evidence.
        # Comment lines stripped first. The prose above this line explains the
        # bug and therefore contains the flag name, and matching it instead of
        # the real invocation is how a test like this quietly asserts nothing.
        code = [l for l in SCRIPT.read_text().splitlines()
                if not l.lstrip().startswith("#")]
        line = next(l for l in code if "--set-env-vars" in l)
        self.assertIn('--set-env-vars "^@^', line,
                      "--set-env-vars does not use the ^delim^ escape; a "
                      "DATASETS_AGENT naming two datasets puts a comma in a "
                      "value and gcloud rejects the whole deploy")
        # Pairs must be joined by the declared delimiter, not by commas.
        for pair in ("@DATASET_MARTS=", "@DATASETS_AGENT="):
            self.assertIn(pair, line,
                          f"pairs are not separated by '@' ({pair} missing), "
                          f"so the ^@^ escape is declared but not used")

    def test_deploy_and_redeploy_ship_the_same_revision(self):
        # Two copies of a `gcloud run deploy` invocation would drift, and the
        # drift would be invisible: both succeed, and only the agent notices
        # that one of them set different env vars.
        # Comment lines stripped first: the script explains the source-build
        # permission trap in prose that names the command, and counting that
        # as an invocation makes this assert nothing useful.
        code = "\n".join(l for l in SCRIPT.read_text().splitlines()
                         if not l.lstrip().startswith("#"))
        self.assertEqual(code.count("gcloud run deploy"), 1,
                         "more than one `gcloud run deploy` invocation; both "
                         "paths must call deploy_service()")
        self.assertIn("deploy_service", self.body())

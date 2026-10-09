"""Each pipeline job runs as its own account, trusted from one workflow file.

Until 2026-10-09 one account, ingest-writer, read all sixteen connector
secrets, wrote raw, staging and marts, and could be borrowed by any workflow
on any branch of the repo. These tests read the setup scripts' dry-run plans
(DRY_RUN=1 prints every command, needs no gcloud) and the workflows, and fail
when an edit widens any of that again:

  - an ingest account may write its own raw dataset and nothing else, and
    read its own secrets and no others;
  - the transform reads raw and writes staging and marts, with no secrets;
  - the probe account writes nothing;
  - every trust binding names one workflow file on main, never the repo;
  - every workflow that authenticates uses its own account's variable, and
    every such workflow is bound in scripts/lib/common.sh.
"""

import os
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
PROJECT = "livewire-dw"
REPO = "hfscdogg/flywheel-warehouse"

# Source -> the workflows that ingest it and the variable they read. The same
# table lives in scripts/lib/common.sh; the tests below hold the two together.
SOURCES = {
    "zoho": ({"ingest-zoho.yml"}, "WIF_SA_INGEST_ZOHO"),
    "zohobilling": ({"ingest-zohobilling.yml"}, "WIF_SA_INGEST_ZOHOBILLING"),
    "dtools": ({"ingest-dtools.yml", "ingest-dtools-v2.yml"}, "WIF_SA_INGEST_DTOOLS"),
    "qbo": ({"ingest-qbo.yml", "ingest-qbo-reports.yml"}, "WIF_SA_INGEST_QBO"),
    "alarmdotcom": ({"ingest-alarmdotcom.yml"}, "WIF_SA_INGEST_ALARMDOTCOM"),
    "vendor": ({"ingest-vendordrop.yml"}, "WIF_SA_INGEST_VENDOR"),
}
OTHER = {"transform.yml": "WIF_SA_TRANSFORM", "probe.yml": "WIF_SA_PROBE",
         "deploy-endpoint.yml": "WIF_DEPLOYER_SERVICE_ACCOUNT"}


def sa(name):
    return f"{name}@{PROJECT}.iam.gserviceaccount.com"


def plan(script, *args):
    env = dict(os.environ, DRY_RUN="1")
    out = subprocess.run([str(ROOT / "scripts" / script), "livewire", *args],
                         capture_output=True, text=True, env=env, cwd=ROOT)
    if out.returncode != 0:
        raise AssertionError(f"{script} dry run failed:\n{out.stdout}\n{out.stderr}")
    return out.stdout


def dataset_grants(text):
    """{(email, role, dataset)} from grant_dataset_role's dry-run lines."""
    return set(re.findall(
        r'access\+=\{"role":"roles/bigquery\.(\w+)","userByEmail":"([^"]+)"\}> '
        + PROJECT + r':(\S+)', text))


def wif_bindings(text):
    """[(account, member)] for every workloadIdentityUser grant in a plan."""
    found = []
    for line in text.splitlines():
        if "roles/iam.workloadIdentityUser" in line and "add-iam-policy-binding" in line:
            account = re.search(r"add-iam-policy-binding (\S+)", line).group(1)
            member = re.search(r"--member=(\S+)", line).group(1)
            found.append((account, member))
    return found


class BigQueryAccess(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.grants = dataset_grants(plan("03-iam.sh"))

    def granted(self, email, role):
        return {ds for r, e, ds in self.grants if e == email and r == role}

    def test_each_ingest_account_writes_its_own_raw_dataset_only(self):
        for src in SOURCES:
            with self.subTest(source=src):
                email = sa(f"ingest-{src}")
                self.assertEqual(self.granted(email, "dataEditor"), {f"raw_{src}"})
                self.assertEqual(self.granted(email, "dataViewer"), set())

    def test_the_transform_reads_raw_and_writes_staging_and_marts(self):
        email = sa("transform-writer")
        self.assertEqual(self.granted(email, "dataEditor"), {"staging", "marts"})
        read = self.granted(email, "dataViewer")
        self.assertTrue(all(ds.startswith("raw_") or ds.startswith("analytics_") for ds in read))
        self.assertIn("raw_qbo", read)

    def test_the_probe_account_writes_nothing(self):
        email = sa("warehouse-reader")
        self.assertEqual(self.granted(email, "dataEditor"), set())
        self.assertTrue({"raw_qbo", "staging", "marts"} <= self.granted(email, "dataViewer"))

    def test_the_retired_account_is_granted_nothing(self):
        self.assertFalse([g for g in self.grants if g[1] == sa("ingest-writer")])

    def test_the_agent_never_writes_or_reads_raw(self):
        email = sa("hermes-reader")
        self.assertEqual(self.granted(email, "dataEditor"), set())
        self.assertFalse([ds for ds in self.granted(email, "dataViewer") if ds.startswith("raw_")])


class SecretsAndTrust(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = plan("05-ingestion-infra.sh")

    def test_each_secret_is_readable_by_its_own_source_only(self):
        seen = 0
        for line in self.text.splitlines():
            m = re.search(r"secrets add-iam-policy-binding (flywheel-\S+) .*"
                          r"--member=serviceAccount:(\S+) --role=roles/secretmanager\.(\w+)", line)
            if not m:
                continue
            seen += 1
            secret, email, role = m.groups()
            owner = email.split("@")[0]
            self.assertTrue(owner.startswith("ingest-"), f"{email} holds {role} on {secret}")
            src = owner[len("ingest-"):]
            self.assertTrue(secret.startswith(f"flywheel-{src}-"),
                            f"{email} may read {secret}, another source's secret")
            if role == "secretVersionAdder":
                self.assertTrue(secret.endswith("refresh-token"))
        self.assertGreaterEqual(seen, 16)

    def test_every_trust_binding_is_one_workflow_on_main(self):
        bindings = wif_bindings(self.text) + wif_bindings(plan("10-endpoint-deployer.sh"))
        self.assertTrue(bindings)
        for account, member in bindings:
            with self.subTest(account=account):
                self.assertNotIn("attribute.repository/", member,
                                 "a repo-wide binding lets any workflow on any branch act as it")
                self.assertRegex(
                    member, r"/attribute\.job_workflow_ref/" + re.escape(REPO)
                    + r"/\.github/workflows/[\w.-]+\.yml@refs/heads/main$")

    def test_which_workflow_may_act_as_which_account(self):
        bound = {}
        for account, member in wif_bindings(self.text) + wif_bindings(plan("10-endpoint-deployer.sh")):
            wf = re.search(r"workflows/([\w.-]+\.yml)@", member).group(1)
            bound.setdefault(account.split("@")[0], set()).add(wf)
        expected = {f"ingest-{src}": wfs for src, (wfs, _) in SOURCES.items()}
        expected.update({"transform-writer": {"transform.yml"},
                         "warehouse-reader": {"probe.yml"},
                         "endpoint-deployer": {"deploy-endpoint.yml"}})
        self.assertEqual(bound, expected)

    def test_the_provider_refuses_other_branches(self):
        self.assertIn("attribute.job_workflow_ref=assertion.job_workflow_ref", self.text)
        self.assertIn("assertion.ref == 'refs/heads/main'", self.text)

    def test_an_existing_provider_is_updated_not_skipped(self):
        # A provider made before the change maps no job_workflow_ref, so the
        # pinned bindings would match nothing until it is updated.
        src = (ROOT / "scripts" / "05-ingestion-infra.sh").read_text()
        self.assertIn("providers update-oidc github", src)


class Workflows(unittest.TestCase):
    def test_each_workflow_authenticates_as_its_own_account(self):
        expected = {wf: var for wfs, var in SOURCES.values() for wf in wfs}
        expected.update(OTHER)
        authenticating = {p.name for p in WORKFLOWS.glob("*.yml")
                          if "google-github-actions/auth" in p.read_text()}
        self.assertEqual(authenticating, set(expected),
                         "a workflow authenticates to Google but is not in the "
                         "table here and in scripts/lib/common.sh")
        for wf, var in expected.items():
            with self.subTest(workflow=wf):
                lines = [l.strip() for l in (WORKFLOWS / wf).read_text().splitlines()
                         if l.strip().startswith("service_account:")]
                self.assertEqual(len(lines), 1)
                self.assertIn(f"vars.{var}", lines[0])

    def test_common_sh_binds_the_same_workflows(self):
        common = (ROOT / "scripts" / "lib" / "common.sh").read_text()
        body = common[common.index("source_workflows() {"):]
        body = body[:body.index("\n}\n")]
        for src, (wfs, _) in SOURCES.items():
            with self.subTest(source=src):
                m = re.search(rf"^\s*{src}\)\s+echo \"([^\"]*)\"", body, re.M)
                self.assertIsNotNone(m)
                self.assertEqual(set(m.group(1).split()), wfs)

    def test_each_pipeline_reads_only_its_own_sources_secrets(self):
        # The account can read nothing else, so a pipeline that reached for
        # another source's secret would fail on its first run after cutover.
        dirs = {"zoho": "zoho", "zohobilling": "zohobilling", "dtools": "dtools",
                "qbo": "qbo", "alarmdotcom": "alarmdotcom"}
        for src, d in dirs.items():
            with self.subTest(source=src):
                text = "".join(p.read_text() for p in (ROOT / "pipelines" / d).glob("*.py"))
                for name in re.findall(r"flywheel-[a-z0-9-]+", text):
                    if name == "flywheel-warehouse":
                        continue
                    self.assertTrue(name.startswith(f"flywheel-{src}-"), f"{d} reads {name}")


class Retirement(unittest.TestCase):
    def test_it_strips_and_disables_ingest_writer(self):
        text = plan("11-retire-ingest-writer.sh")
        email = sa("ingest-writer")
        self.assertRegex(text, r"remove-iam-policy-binding " + re.escape(email)
                         + r" .*attribute\.repository/" + re.escape(REPO))
        self.assertIn(f"service-accounts disable {email}", text)
        for ds in ("raw_qbo", "staging", "marts"):
            self.assertIn(f'"role":"roles/bigquery.dataEditor","userByEmail":"{email}"}}> {PROJECT}:{ds}', text)
        self.assertGreaterEqual(text.count(f"--member=serviceAccount:{email} --role=roles/secretmanager.secretAccessor"), 16)

    def test_it_refuses_before_the_new_accounts_exist(self):
        src = (ROOT / "scripts" / "11-retire-ingest-writer.sh").read_text()
        self.assertIn("these accounts do not exist yet", src)
        self.assertIn("does not map job_workflow_ref", src)
        self.assertLess(src.index("does not map job_workflow_ref"),
                        src.index("remove_resource_binding"))


if __name__ == "__main__":
    unittest.main()

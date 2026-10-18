"""The lifecycle scripts undo what they do, and verify what must be absent.

Read from the dry-run plans (DRY_RUN=1 prints every command, needs no gcloud):

  - narrowing AGENT_SCOPE revokes hermes-reader's staging grant, not only
    stops adding it;
  - 11-retire strips ingest-writer and wif-rehearsal from every policy,
    deletes wif-rehearsal and any second WIF provider;
  - 99-teardown --revoke-agent takes staging too, and --full removes the
    endpoint, every secret and the federation, not just the accounts;
  - 90-verify asserts the retired and rehearsal paths are absent.

The WIF pool is shared with other repositories. SharedPool runs the WIF
helpers in lib/common.sh against a stand-in gcloud (a JSON state file that
providers and bindings are read from and deleted out of): another
repository's provider and binding survive retire, teardown and verify, while
this repository's stray providers and repo-wide binding still go.
"""

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = "livewire-dw"


def sa(name):
    return f"{name}@{PROJECT}.iam.gserviceaccount.com"


def plan(script, *args, root=ROOT):
    env = dict(os.environ, DRY_RUN="1")
    out = subprocess.run([str(root / "scripts" / script), "livewire", *args],
                         capture_output=True, text=True, env=env, cwd=root)
    if out.returncode != 0:
        raise AssertionError(f"{script} dry run failed:\n{out.stdout}\n{out.stderr}")
    return out.stdout


def revoked_from_agent(text):
    """Datasets the plan takes hermes-reader off, in either removal form."""
    email = sa("hermes-reader")
    found = set()
    for line in text.splitlines():
        if "bq update --source <access-=" in line and email in line:
            found.add(line.rsplit(f"{PROJECT}:", 1)[1].strip())
    return found


class ScopeNarrowing(unittest.TestCase):
    def test_wide_keeps_staging_and_revokes_the_rest(self):
        revoked = revoked_from_agent(plan("03-iam.sh"))
        self.assertNotIn("staging", revoked)
        self.assertNotIn("marts", revoked)
        self.assertTrue({"raw_zoho", "raw_qbo", "analytics_285482813"} <= revoked)

    def test_narrow_revokes_staging(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            shutil.copytree(ROOT / "scripts", root / "scripts")
            shutil.copytree(ROOT / "clients", root / "clients")
            env = root / "clients" / "livewire" / "client.env"
            text = env.read_text()
            self.assertIn('AGENT_SCOPE="wide"', text)
            env.write_text(text.replace('AGENT_SCOPE="wide"', 'AGENT_SCOPE="narrow"'))
            revoked = revoked_from_agent(plan("03-iam.sh", root=root))
        self.assertIn("staging", revoked)
        self.assertNotIn("marts", revoked)


class Retirement(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = plan("11-retire-ingest-writer.sh")

    def test_both_accounts_are_taken_off_every_policy(self):
        for name in ("ingest-writer", "wif-rehearsal"):
            with self.subTest(account=name):
                self.assertIn(f"remove every binding naming {sa(name)}", self.text)

    def test_the_rehearsal_account_is_deleted(self):
        self.assertIn(f"service-accounts delete {sa('wif-rehearsal')}", self.text)

    def test_second_providers_and_loose_bindings_go(self):
        self.assertIn("delete every WIF provider but flywheel-github/github", self.text)
        self.assertIn("remove every federated binding that is not one workflow file", self.text)

    def test_no_early_exit_when_ingest_writer_is_gone(self):
        src = (ROOT / "scripts" / "11-retire-ingest-writer.sh").read_text()
        self.assertNotIn("nothing to retire", src)


class Teardown(unittest.TestCase):
    def test_revoke_agent_takes_staging_too(self):
        text = plan("99-teardown.sh", "--revoke-agent", "--yes")
        email = sa("hermes-reader")
        self.assertIn(f'"userByEmail":"{email}"}}> {PROJECT}:staging', text)
        self.assertIn(f'"userByEmail":"{email}"}}> {PROJECT}:marts', text)

    def test_full_removes_endpoint_secrets_and_federation(self):
        text = plan("99-teardown.sh", "--full", "--yes")
        self.assertIn("gcloud run services delete hermes-mcp", text)
        for secret in ("hermes-endpoint-token", "flywheel-zoho-refresh-token",
                       "flywheel-qbo-refresh-token", "flywheel-dtools-v2-refresh-token"):
            with self.subTest(secret=secret):
                self.assertIn(f"gcloud secrets delete {secret} ", text)
        self.assertIn("gcloud iam workload-identity-pools delete flywheel-github", text)
        self.assertIn("delete every WIF provider but flywheel-github/github", text)
        for name in ("hermes-reader", "ingest-zoho", "transform-writer", "endpoint-deployer",
                     "endpoint-builder", "ingest-writer", "wif-rehearsal"):
            with self.subTest(account=name):
                self.assertIn(f"service-accounts delete {sa(name)}", text)
        self.assertIn("gcloud iam roles delete flywheelSourceBucketLister", text)

    def test_the_endpoint_goes_before_its_identity(self):
        text = plan("99-teardown.sh", "--full", "--yes")
        self.assertLess(text.index("run services delete hermes-mcp"),
                        text.index(f"service-accounts delete {sa('hermes-reader')}"))


class VerifyAbsence(unittest.TestCase):
    def test_the_plan_names_every_absence(self):
        text = plan("90-verify.sh")
        self.assertIn(f"{sa('ingest-writer')} is named in no policy", text)
        self.assertIn(f"{sa('wif-rehearsal')} does not exist and is named in no policy", text)
        self.assertIn("the only WIF provider accepting GitHub tokens is flywheel-github/github", text)
        self.assertIn("every federated binding names one workflow file", text)
        self.assertIn("no grant on any project dataset outside", text)


# ── A stand-in gcloud for the WIF helpers ──────────────────────────────────
# Serves pools, providers, service accounts and their IAM policies from the
# JSON file in $FAKE_GCLOUD_STATE, applies deletes and binding removals to
# it, and fails on any command it does not know.
FAKE_GCLOUD = r"""#!/usr/bin/env python3
import json, os, sys

path = os.environ["FAKE_GCLOUD_STATE"]
state = json.load(open(path))
pos, flags = [], {}
args = sys.argv[1:]
i = 0
while i < len(args):
    a = args[i]
    if a.startswith("--"):
        if "=" in a:
            k, v = a[2:].split("=", 1)
        elif a == "--quiet":
            k, v = "quiet", True
        else:
            k, v = a[2:], args[i + 1]
            i += 1
        flags[k] = v
    else:
        pos.append(a)
    i += 1
fmt = flags.get("format", "")
pools = state["pools"]
base = "projects/%s/locations/global/workloadIdentityPools/" % state["number"]

def save():
    json.dump(state, open(path, "w"))

def fail():
    sys.stderr.write("stand-in gcloud: unhandled %r\n" % sys.argv[1:])
    sys.exit(2)

if pos[:2] == ["iam", "workload-identity-pools"]:
    if pos[2] == "list":
        for p in pools:
            print(p if fmt == "value(name.basename())" else base + p)
    elif pos[2] == "describe":
        if pos[3] not in pools:
            sys.exit(1)
        print(base + pos[3])
    elif pos[2] == "delete":
        if pos[3] not in pools:
            sys.exit(1)
        del pools[pos[3]]
        save()
    elif pos[2] == "providers":
        pool = flags["workload-identity-pool"]
        provs = pools.get(pool)
        if provs is None:
            sys.exit(1)
        if pos[3] == "list":
            rows = [dict(v, name=base + pool + "/providers/" + k, state="ACTIVE")
                    for k, v in provs.items()]
            if fmt == "json":
                print(json.dumps(rows))
            else:
                for r in rows:
                    print(r["name"])
        elif pos[3] == "describe":
            if pos[4] not in provs:
                sys.exit(1)
            if fmt.startswith("value("):
                print(provs[pos[4]].get(fmt[6:-1], ""))
        elif pos[3] == "delete":
            if pos[4] not in provs:
                sys.exit(1)
            del provs[pos[4]]
            save()
        else:
            fail()
    else:
        fail()
elif pos[:2] == ["iam", "service-accounts"]:
    policies = state["policies"]
    if pos[2] == "list":
        for email in policies:
            print(email)
    elif pos[2] == "get-iam-policy":
        print(json.dumps(policies[pos[3]]))
    elif pos[2] == "remove-iam-policy-binding":
        for b in policies[pos[3]]["bindings"]:
            if b["role"] == flags["role"] and flags["member"] in b["members"]:
                b["members"].remove(flags["member"])
        save()
    else:
        fail()
else:
    fail()
"""

NUMBER = "711707450526"
REPO = "hfscdogg/flywheel-warehouse"
KITCHEN = "hfscdogg/flywheel-kitchen"
POOL_NAME = f"projects/{NUMBER}/locations/global/workloadIdentityPools/flywheel-github"
KITCHEN_MEMBER = (f"principalSet://iam.googleapis.com/{POOL_NAME}/attribute.job_workflow_ref/"
                  f"{KITCHEN}/.github/workflows/weekly-brief.yml@refs/heads/main")
KITCHEN_REPO_MEMBER = f"principalSet://iam.googleapis.com/{POOL_NAME}/attribute.repository/{KITCHEN}"
PINNED_MEMBER = (f"principalSet://iam.googleapis.com/{POOL_NAME}/attribute.job_workflow_ref/"
                 f"{REPO}/.github/workflows/ingest-zoho.yml@refs/heads/main")
REPO_WIDE_MEMBER = f"principalSet://iam.googleapis.com/{POOL_NAME}/attribute.repository/{REPO}"
GONE_POOL_MEMBER = (f"principalSet://iam.googleapis.com/projects/{NUMBER}/locations/global/"
                    f"workloadIdentityPools/rehearsal/attribute.repository/{REPO}")
WIU = "roles/iam.workloadIdentityUser"


def provider(condition=None):
    p = {"oidc": {"issuerUri": "https://token.actions.githubusercontent.com"}}
    if condition is not None:
        p["attributeCondition"] = condition
    return p


def pinned(repo):
    return f"assertion.repository == '{repo}' && assertion.ref == 'refs/heads/main'"


def live_state(stray=True):
    """The shared pool as it is live (github and github-kitchen, kitchen-runner
    bound to one kitchen workflow), plus, when stray, providers and bindings
    for this repository that retirement must remove."""
    pools = {
        "flywheel-github": {
            "github": provider(pinned(REPO)),
            "github-kitchen": provider(pinned(KITCHEN)),
        },
    }
    policies = {
        sa("kitchen-runner"): {"bindings": [{"role": WIU, "members": [KITCHEN_MEMBER]}]},
        sa("ingest-zoho"): {"bindings": [{"role": WIU, "members": [PINNED_MEMBER]}]},
    }
    if stray:
        # Second ways in for this repository: one pinned to this repository
        # on any branch in the shared pool, an unconditioned one in a pool of
        # its own, and one next to another repository's provider.
        pools["flywheel-github"]["rehearsal"] = provider(f"assertion.repository == '{REPO}'")
        pools["legacy"] = {"open": provider()}
        pools["mixed"] = {"open": provider(), "kitchen-2": provider(pinned(KITCHEN))}
        policies[sa("ingest-zoho")]["bindings"][0]["members"].append(REPO_WIDE_MEMBER)
        policies[sa("transform-writer")] = {"bindings": [
            {"role": WIU, "members": [GONE_POOL_MEMBER]}]}
        policies[sa("kitchen-runner")]["bindings"][0]["members"].append(KITCHEN_REPO_MEMBER)
    return {"number": NUMBER, "pools": pools, "policies": policies}


class SharedPool(unittest.TestCase):
    """Another repository's provider and binding in the shared pool survive."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        tmp = pathlib.Path(self.tmp.name)
        (tmp / "bin").mkdir()
        gcloud = tmp / "bin" / "gcloud"
        gcloud.write_text(FAKE_GCLOUD)
        gcloud.chmod(0o755)
        self.state_file = tmp / "state.json"
        self.env = dict(os.environ, DRY_RUN="0", PATH=f"{tmp / 'bin'}:{os.environ['PATH']}",
                        FAKE_GCLOUD_STATE=str(self.state_file), GCP_PROJECT_ID=PROJECT,
                        WIF_POOL="flywheel-github", GITHUB_REPO=REPO,
                        WIF_ALLOWED_REF="refs/heads/main")

    def tearDown(self):
        self.tmp.cleanup()

    def load(self, state):
        self.state_file.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.state_file.read_text())

    def bash(self, script):
        out = subprocess.run(["bash", "-c", f"set -euo pipefail; . scripts/lib/common.sh; {script}"],
                             capture_output=True, text=True, env=self.env, cwd=ROOT)
        if out.returncode != 0:
            raise AssertionError(f"{script} failed:\n{out.stdout}\n{out.stderr}")
        return out.stdout

    def members(self, account):
        return [m for b in self.state()["policies"][account]["bindings"] for m in b["members"]]

    def assert_kitchen_untouched(self):
        pools = self.state()["pools"]
        self.assertIn("github-kitchen", pools.get("flywheel-github", {}))
        self.assertEqual(pools["flywheel-github"]["github-kitchen"]["attributeCondition"],
                         pinned(KITCHEN))
        self.assertIn(KITCHEN_MEMBER, self.members(sa("kitchen-runner")))

    def test_retire_keeps_kitchen_and_removes_this_repos_strays(self):
        self.load(live_state())
        self.bash(f'delete_stray_wif_providers; remove_loose_wif_bindings "{POOL_NAME}"')
        self.assert_kitchen_untouched()
        self.assertIn(KITCHEN_REPO_MEMBER, self.members(sa("kitchen-runner")))
        pools = self.state()["pools"]
        self.assertEqual(set(pools["flywheel-github"]), {"github", "github-kitchen"})
        self.assertNotIn("legacy", pools)
        self.assertEqual(set(pools["mixed"]), {"kitchen-2"})
        self.assertEqual(self.members(sa("ingest-zoho")), [PINNED_MEMBER])
        self.assertEqual(self.members(sa("transform-writer")), [])

    def test_retire_uses_the_scoped_helpers(self):
        src = (ROOT / "scripts" / "11-retire-ingest-writer.sh").read_text()
        self.assertIn("delete_stray_wif_providers", src)
        self.assertIn('remove_loose_wif_bindings "$POOL_NAME"', src)
        self.assertNotIn("remove-iam-policy-binding", src)

    def test_teardown_keeps_the_shared_pool_and_kitchen(self):
        self.load(live_state())
        self.bash("delete_wif_federation")
        self.assert_kitchen_untouched()
        pools = self.state()["pools"]
        self.assertEqual(set(pools["flywheel-github"]), {"github-kitchen"})
        self.assertNotIn("legacy", pools)
        self.assertEqual(set(pools["mixed"]), {"kitchen-2"})

    def test_teardown_deletes_the_pool_when_only_this_repo_uses_it(self):
        state = live_state()
        del state["pools"]["flywheel-github"]["github-kitchen"]
        self.load(state)
        self.bash("delete_wif_federation")
        self.assertNotIn("flywheel-github", self.state()["pools"])

    def test_teardown_uses_the_scoped_helper(self):
        src = (ROOT / "scripts" / "99-teardown.sh").read_text()
        self.assertIn("delete_wif_federation", src)
        self.assertNotIn("workload-identity-pools delete", src)

    def test_verify_passes_with_kitchen_present(self):
        self.load(live_state(stray=False))
        self.assertEqual(self.bash("stray_wif_providers"), "")
        self.assertEqual(self.bash(f'loose_wif_bindings "{POOL_NAME}"'), "")
        self.assert_kitchen_untouched()

    def test_verify_still_finds_this_repos_strays(self):
        self.load(live_state())
        stray = set(self.bash("stray_wif_providers").splitlines())
        self.assertEqual(stray, {"flywheel-github\trehearsal", "legacy\topen", "mixed\topen"})
        loose = {line.split("\t")[2] for line in
                 self.bash(f'loose_wif_bindings "{POOL_NAME}"').splitlines()}
        self.assertEqual(loose, {REPO_WIDE_MEMBER, GONE_POOL_MEMBER})

    def test_verify_uses_the_scoped_helpers(self):
        src = (ROOT / "scripts" / "90-verify.sh").read_text()
        self.assertIn('STRAY="$(stray_wif_providers)"', src)
        self.assertIn('LOOSE="$(loose_wif_bindings "$POOL_NAME")"', src)


if __name__ == "__main__":
    unittest.main()

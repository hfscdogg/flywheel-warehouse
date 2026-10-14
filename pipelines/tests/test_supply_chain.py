"""Nothing a workflow runs can change underneath a minted credential.

A tag (`@v3`) or an unpinned requirement (`requests>=2.32`) is resolved at
run time, so whoever controls the upstream tag or package controls what runs
next to the WIF token. These tests fail when an edit reintroduces either:

  - every third-party action is pinned to a full 40-character commit SHA;
  - every Python requirements file pins each package with a hash;
  - in every job that authenticates to Google, every install step (setup-*,
    pip install) runs before the auth step mints the credential, and pip
    installs with --require-hashes.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
REQUIREMENTS = [ROOT / "pipelines" / "requirements.txt",
                ROOT / "hermes-mcp" / "requirements.txt"]

USES = re.compile(r"^\s*(?:-\s+)?uses:\s*([^\s#]+)", re.M)
STEP = re.compile(r"^      - ", re.M)


def workflows():
    return sorted(WORKFLOWS.glob("*.yml"))


def steps(src):
    """The step blocks of each job, split on the six-space '- ' marker."""
    jobs = re.split(r"^    steps:\n", src, flags=re.M)[1:]
    for job in jobs:
        # A job's steps end where the next top-level job key starts.
        job = re.split(r"^  \S", job, maxsplit=1, flags=re.M)[0]
        yield [b for b in STEP.split(job) if b.strip()]


class ActionsArePinned(unittest.TestCase):
    def test_every_action_is_a_commit_sha(self):
        for wf in workflows():
            for ref in USES.findall(wf.read_text()):
                if ref.startswith("./"):
                    continue  # a workflow in this repo, pinned by the checkout
                with self.subTest(workflow=wf.name, uses=ref):
                    self.assertRegex(ref, r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$",
                                     "pin the action to a full commit SHA, "
                                     "with the tag as a trailing comment")


class RequirementsAreHashed(unittest.TestCase):
    def test_every_requirement_has_a_hash(self):
        for req in REQUIREMENTS:
            # pip's requirement lines continue with a trailing backslash.
            entries = re.split(r"(?<!\\)\n", req.read_text())
            for entry in entries:
                line = entry.strip()
                if not line or line.startswith("#"):
                    continue
                with self.subTest(file=str(req.relative_to(ROOT)), line=line.split()[0]):
                    self.assertRegex(line.split()[0], r"^[A-Za-z0-9_.\[\],-]+==\S+$",
                                     "pin an exact version")
                    self.assertIn("--hash=sha256:", line)

    def test_the_loose_specs_are_kept_beside_the_lock(self):
        for req in REQUIREMENTS:
            self.assertTrue(req.with_suffix(".in").exists(),
                            f"{req.with_suffix('.in')} is what the lock is compiled from")


class InstallBeforeCredential(unittest.TestCase):
    def test_nothing_is_installed_after_auth(self):
        for wf in workflows():
            for job in steps(wf.read_text()):
                auth = [i for i, s in enumerate(job) if "google-github-actions/auth@" in s]
                if not auth:
                    continue
                for i, s in enumerate(job):
                    installs = ("actions/setup-" in s or "setup-gcloud@" in s
                                or "pip install" in s)
                    if installs:
                        with self.subTest(workflow=wf.name, step=s.splitlines()[0]):
                            self.assertLess(i, auth[0], "install before the WIF token is minted")

    def test_pip_checks_hashes(self):
        for wf in workflows():
            for line in wf.read_text().splitlines():
                if "pip install" in line:
                    with self.subTest(workflow=wf.name):
                        self.assertIn("--require-hashes", line)


if __name__ == "__main__":
    unittest.main()

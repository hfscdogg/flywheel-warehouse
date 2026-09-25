"""One-time D-Tools Cloud v2 sign-in: device code → refresh token → Secret Manager.

Run on your own machine, with gcloud signed in as someone who can add secret
versions in the client's project:

    python -m pipelines.dtools.signin --client livewire

It prints a Microsoft URL and a code. Open the URL, enter the code, and sign in
as the D-Tools SERVICE USER (not your own login: the nightly ingest acts as
whoever signs in here). The refresh token goes straight to
`gcloud secrets versions add` on stdin; it is never printed, logged or written
to disk. The script then lists the D-Tools accounts that user can reach, so
DTOOLS_V2_ACCOUNT_ID can be set when there is more than one.

Re-run it whenever the ingest fails with "refused the stored refresh token".

Stdlib only (urllib, subprocess), so it needs nothing beyond python3 and
gcloud, and the suite can test it.
"""

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from ..lib import config
from ..lib.sources import DTOOLS_V2
from .v2 import settings, token_url

DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"


def post_form(url, fields):
    """POST a form; (status, parsed JSON body) for success and failure alike."""
    req = urllib.request.Request(
        url, data=urllib.parse.urlencode(fields).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}


def start_device_code(st, post=post_form):
    status, body = post(f"{st['authority']}/oauth2/v2.0/devicecode", {
        "client_id": st["client_id"],
        # offline_access is what makes Entra return a refresh token at all.
        "scope": f"{st['scope']} offline_access openid profile",
    })
    if status != 200:
        raise SystemExit(f"device-code request refused ({status}): "
                         f"{body.get('error')}: {body.get('error_description')}")
    return body


def poll_for_tokens(st, dc, post=post_form, sleep=time.sleep, clock=time.monotonic):
    """Poll the token endpoint until the person finishes signing in."""
    interval = int(dc.get("interval", 5))
    deadline = clock() + int(dc.get("expires_in", 900))
    while clock() < deadline:
        sleep(interval)
        status, body = post(token_url(st), {
            "grant_type": DEVICE_GRANT,
            "client_id": st["client_id"],
            "device_code": dc["device_code"],
        })
        if status == 200:
            return body
        err = body.get("error")
        if err == "authorization_pending":
            continue
        if err == "slow_down":
            interval += 5
            continue
        raise SystemExit(f"sign-in did not complete: {err}: {body.get('error_description')}")
    raise SystemExit("sign-in timed out: the code expired before anyone signed in")


def store_refresh_token(project_id, secret, value, run=subprocess.run):
    """Add the token as a new secret version, creating the secret if absent.

    The value travels on stdin only: never argv (visible in the process
    list), never a file.
    """
    exists = run(["gcloud", "secrets", "describe", secret, "--project", project_id],
                 capture_output=True, text=True).returncode == 0
    if not exists:
        run(["gcloud", "secrets", "create", secret, "--project", project_id,
             "--replication-policy=automatic"],
            check=True, capture_output=True, text=True)
    run(["gcloud", "secrets", "versions", "add", secret, "--project", project_id,
         "--data-file=-"], input=value, check=True, capture_output=True, text=True)


def list_accounts(st, access_token):
    req = urllib.request.Request(
        f"{st['base_url']}/me/accounts",
        headers={"Authorization": f"Bearer {access_token}", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read() or b"{}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--client", default="livewire")
    args = p.parse_args(argv)
    cfg = config.load_client(args.client)
    st = settings(cfg.env)

    dc = start_device_code(st)
    print(dc.get("message") or
          f"Open {dc['verification_uri']} and enter the code {dc['user_code']}")
    print("Sign in as the D-Tools SERVICE USER. Waiting...", flush=True)
    tokens = poll_for_tokens(st, dc)

    refresh = tokens.get("refresh_token")
    if not refresh:
        raise SystemExit("Entra returned no refresh token; the scope must include offline_access")
    secret = DTOOLS_V2["refresh_secret"]
    store_refresh_token(cfg.project_id, secret, refresh)
    print(f"Stored as a new version of {secret} in {cfg.project_id} (not printed).")

    try:
        me = list_accounts(st, tokens["access_token"])
    except (urllib.error.URLError, ValueError) as e:
        print(f"Could not list accounts ({e}); the token is stored regardless.")
        return 0
    accounts = me.get("accounts") or []
    print(f"Signed in as {me.get('email')}; D-Tools accounts reachable: {len(accounts)}")
    for a in accounts:
        print(f"  accountId={a.get('accountId')}  {a.get('accountName')}")
    if len(accounts) > 1 and not st["account_id"]:
        print("More than one account: set DTOOLS_V2_ACCOUNT_ID in client.env "
              "to Livewire's, or every call fails with account_selection_required.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

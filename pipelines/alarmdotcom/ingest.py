"""Alarm.com Partner Portal → raw_alarmdotcom. Full pull per run.

Auth: OAuth password grant against /AdminApiAccess/token using a rep's
username and password, the app's client id and the rep's two-factor web
service token, all from the client's Secret Manager (see Token). The bearer
token it returns authorizes PartnerApi calls.

Why full pull: the API documents no modified-time filter, and the audit
needs the whole account roster anyway — including accounts we may have
stopped billing for, which is the entire point.

Env:
  ALARMDOTCOM_DEALER_ID  required — the dealer whose customers to pull
  ALARMDOTCOM_API_VERSION  optional override (docs show both v1 and v1.0)
"""

import logging

from ..lib import runner, util
from ..lib.sources import ALARMDOTCOM

log = logging.getLogger("flywheel.ingest.alarmdotcom")


TWOFACTOR_SECRET = "flywheel-alarmdotcom-twofactor-device-id"
# Renew this long before the token's stated expiry: a page fetched with a
# token that lapses mid-request fails the whole run.
RENEW_MARGIN_S = 120


class Token:
    """A bearer token for the Partner API, renewed before it expires.

    Alarm.com requires two-factor on the rep login used for the API
    (webservices@alarm.com, 2026-08-31). An unattended job cannot type a
    code; the rep's "web service token" (Partner Portal profile > Two
    factor authentication > Generate a web service token) is sent instead,
    as x_twofactor_device_id, which the Auth reference marks "Required for
    password grant_type if client has 2FA enabled".

    Tokens last about 15 minutes (expires_in 899). Each renewal uses the
    refresh token the last grant returned, and falls back to a fresh
    password grant only if that is refused, so a long pull signs in with
    the password once. Alarm.com locks a login after repeated failed
    sign-ins, so a refused password grant is never retried.
    """

    def __init__(self, http, project_id, clock=None):
        import time
        self.http, self.project_id = http, project_id
        self.clock = clock or time.monotonic
        self.access, self.refresh, self.expires_at = None, None, 0.0

    def _secret(self, name):
        from ..lib import secret_store
        return secret_store.get(self.project_id, name)

    def _grant(self, data):
        resp = self.http.post(ALARMDOTCOM["token_url"], data=data, headers={
            "Content-Type": "application/x-www-form-urlencoded"}, timeout=30)
        try:
            body = resp.json()
        except ValueError:
            body = {}
        return resp, body if isinstance(body, dict) else {}

    def _password_grant(self):
        resp, body = self._grant({
            "grant_type": "password",
            "username": self._secret("flywheel-alarmdotcom-username"),
            "password": self._secret("flywheel-alarmdotcom-password"),
            "client_id": self._secret("flywheel-alarmdotcom-client-id"),
            "x_twofactor_device_id": self._secret(TWOFACTOR_SECRET),
        })
        if resp.status_code >= 400 or "access_token" not in body:
            # Never retried: repeated failures lock the rep login.
            raise RuntimeError(
                "Alarm.com refused the sign-in "
                f"({resp.status_code} {body.get('error', '')}: "
                f"{body.get('error_description', '')}). Check the rep username, "
                f"password and web service token ({TWOFACTOR_SECRET}) before "
                "running again: Alarm.com locks a login after repeated failures.")
        return body

    def _refresh_grant(self):
        resp, body = self._grant({
            "grant_type": "refresh_token",
            "refresh_token": self.refresh,
            "client_id": self._secret("flywheel-alarmdotcom-client-id"),
        })
        if resp.status_code >= 400 or "access_token" not in body:
            log.info("Alarm.com refresh refused (%s); signing in again", resp.status_code)
            return None
        return body

    def bearer(self):
        if self.access and self.clock() < self.expires_at - RENEW_MARGIN_S:
            return self.access
        body = (self._refresh_grant() if self.refresh else None) or self._password_grant()
        self.access = body["access_token"]
        self.refresh = body.get("refresh_token") or self.refresh
        self.expires_at = self.clock() + float(body.get("expires_in") or 899)
        return self.access


def records_from(body, entity_name):
    """Unwrap a page. The docs show bare objects; list endpoints may wrap.

    Handles a bare array, or an object carrying the list under a common key
    ('data', 'items', 'results', or the entity name) — whichever the API
    actually returns, rather than guessing one and failing on the others.
    """
    if isinstance(body, list):
        return body
    if isinstance(body, dict):
        for key in ("data", "items", "results", entity_name):
            value = body.get(key)
            if isinstance(value, list):
                return value
    return []


def _get(http, token, url, params=None):
    return http.get(url, headers={"Authorization": f"Bearer {token.bearer()}"},
                    params=params, timeout=60)


def list_customer_ids(http, token, dealer_id, page_size, max_pages=500):
    """Every customer id the rep can see for the dealer, terminated included.

    GET /v1/customers "Retrieves customer ids that your login has access to
    matching the optional search parameters", as [{"customerId": n}, ...],
    and "Returns 0 if the customer is not found", so 0 is dropped.

    Paging: searchParameters.pageNumber / pageSize. The docs do not say
    whether pages count from 0 or 1, so this starts at 0 and keeps ids in
    order without duplicates: if 0 is read as the first page nothing is
    skipped, and if the API treats it as page 1, page 1 repeats it and adds
    nothing. It stops at a short page, or at a page after that adds no new
    id (an API ignoring the page number).
    Terminated accounts are included (includeTermed): accounts we may still
    be billed for after they ended are what the audit looks for.
    """
    url = f"{ALARMDOTCOM['base_url']}/{api_version()}/customers"
    ids, seen = [], set()
    for page in range(max_pages):
        resp = _get(http, token, url, params={
            "searchParameters.dealerId": dealer_id,
            "searchParameters.includeTermed": "true",
            "searchParameters.pageNumber": page,
            "searchParameters.pageSize": page_size,
        })
        if resp.status_code == 204:
            break
        util.raise_for_status(resp, "Alarm.com customer ids")
        batch = records_from(resp.json(), "customers")
        new = [r.get("customerId") for r in batch
               if isinstance(r, dict) and r.get("customerId") and r.get("customerId") not in seen]
        for cid in new:
            seen.add(cid)
            ids.append(cid)
        if len(batch) < page_size:
            return ids
        # Page 1 repeating page 0 is the API counting from 1; any later page
        # adding nothing means it is ignoring the page number.
        if not new and page != 1:
            return ids
    raise RuntimeError("Alarm.com customer id paging did not terminate after "
                       f"{max_pages} pages; check the searchParameters.page* names")


def fetch_customers(http, token, dealer_id, limit=0, pause=None):
    """(records, skipped): the full record of every customer id listed.

    GET /v1/customers/{id} per customer: the API has no bulk read. A rep
    who cannot see one account gets 403 or 404 for it; that account is
    skipped and counted rather than failing the run, unless most of them
    fail, which means the rep or token is wrong rather than one account.

    A terminated account is listed (includeTermed) but its record is not
    served: 400 {"message": "This Customer is already terminated."} (first
    live run, 2026-11-04). It lands as a stub, its id with isTerminated
    true and that message, so the audit still sees an account that existed
    and ended. Stubs are not refusals and do not count toward the check.
    """
    import time
    pause = ALARMDOTCOM["pause_s"] if pause is None else pause
    ids = list_customer_ids(http, token, dealer_id, ALARMDOTCOM["page_size"])
    if limit:
        ids = ids[:limit]
    log.info("Alarm.com: %d customer ids for dealer %s", len(ids), dealer_id)
    url = f"{ALARMDOTCOM['base_url']}/{api_version()}/customers"
    records, skipped = [], []
    for cid in ids:
        resp = _get(http, token, f"{url}/{cid}")
        if resp.status_code in (403, 404):
            skipped.append((cid, resp.status_code))
        elif resp.status_code == 400 and _terminated(resp):
            records.append({"customerId": cid, "isTerminated": True,
                            "detailUnavailable": _message(resp)})
        else:
            util.raise_for_status(resp, f"Alarm.com customer {cid}")
            record = resp.json()
            if isinstance(record, dict):
                record.setdefault("customerId", cid)
                records.append(record)
        if pause:
            time.sleep(pause)
    if ids and len(skipped) > len(ids) / 2:
        raise RuntimeError(f"Alarm.com refused {len(skipped)} of {len(ids)} customer "
                           f"records (first: {skipped[:3]}); check the rep's permissions")
    for cid, status in skipped[:20]:
        log.warning("Alarm.com customer %s: HTTP %s, skipped", cid, status)
    return records, skipped


def _message(resp):
    try:
        body = resp.json()
    except ValueError:
        return ""
    return str(body.get("message", "")) if isinstance(body, dict) else ""


def _terminated(resp):
    return "terminated" in _message(resp).lower()


def api_version():
    return util.env_or("ALARMDOTCOM_API_VERSION", ALARMDOTCOM["api_version"])


def main():
    entity_names = [e["name"] for e in ALARMDOTCOM["entities"]]
    args, cfg, dataset, run_id = runner.setup("alarmdotcom", entity_names)
    from ..lib import bq as bq_mod
    from ..lib import web

    bq = bq_mod.client_for(cfg)
    # Landing tables exist before the credential check, not after it. A source
    # can sit in DATASETS_RAW for a while before anyone finishes setting it up,
    # and downstream models read tables, not intentions: without this,
    # stg_alarmdotcom__customers is skipped for a missing table and any mart
    # that reads it is skipped in turn — which would take the working Security
    # Central audit down with it the moment Alarm.com joins that mart.
    for entity in ALARMDOTCOM["entities"]:
        bq_mod.ensure_table(bq, cfg, dataset, entity["name"].lower(),
                            bq_mod.LANDING_SCHEMA)

    # No dealer id means nobody has finished wiring this source up yet. That is
    # a setup state, not a failure, and failing it nightly only teaches an
    # operator to ignore a red ingest. Anything past this point — a bad
    # credential, an API error — is a real failure and still raises.
    dealer_id = util.env_or("ALARMDOTCOM_DEALER_ID")
    if not dealer_id:
        log.warning(
            "ALARMDOTCOM_DEALER_ID is not set — Alarm.com is enabled but not "
            "credentialed yet, so there is nothing to pull. Landing tables are "
            "in place; see docs/phase-2-credentials.md section 2b.")
        return

    http = web.session()
    token = Token(http, cfg.project_id)

    entity = ALARMDOTCOM["entities"][0]
    records, skipped = fetch_customers(http, token, dealer_id, args.limit)
    total = runner.land(bq_mod, bq, cfg, dataset, entity["name"], records,
                        entity["id_field"], ALARMDOTCOM["modified_field"], run_id)
    log.info("done: %d customers landed, %d skipped (no access)", total, len(skipped))


if __name__ == "__main__":
    main()

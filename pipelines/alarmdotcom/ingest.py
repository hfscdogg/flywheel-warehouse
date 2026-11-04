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
  ALARMDOTCOM_FIELDS  optional override for the `fields` projection (default *)
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


def fetch_entity(http, token, dealer_id, entity, limit):
    """All pages of one entity. token is a Token, asked for a bearer per page."""
    version = util.env_or("ALARMDOTCOM_API_VERSION", ALARMDOTCOM["api_version"])
    path = entity["path"].format(dealer_id=dealer_id)
    url = f"{ALARMDOTCOM['base_url']}/{version}/{path}"
    page_size = ALARMDOTCOM["page_size"]
    # Ask for every field. The API documents a `fields` projection whose
    # wildcard is `*` — and a wildcard is only worth documenting if the
    # default is something narrower. Their own list example asks for
    # `?fields=customerId,address/street1` rather than relying on a default.
    # Omitting it risks a partial payload that reads exactly like a wrong
    # JSON path: an all-NULL address column, and a day spent debugging the
    # model instead of the request. Same shape as the NULL plan_code in #18
    # and the absent Billing addresses in #25.
    fields = util.env_or("ALARMDOTCOM_FIELDS", "*")
    records, page = [], 1
    while True:
        resp = http.get(url, headers={"Authorization": f"Bearer {token.bearer()}"},
                        params={"page": page, "pageSize": page_size,
                                "fields": fields}, timeout=60)
        if resp.status_code == 204:
            break
        util.raise_for_status(resp, f"Alarm.com {entity['name']}")
        batch = records_from(resp.json(), entity["name"])
        if not batch:
            break
        records.extend(batch)
        if limit and len(records) >= limit:
            return records[:limit]
        # A short page is the last page. If the API ignores paging entirely it
        # returns the same full page forever, so stop once a page repeats.
        if len(batch) < page_size:
            break
        page += 1
        if page > 500:  # runaway guard: 100k accounts is far beyond any dealer
            raise RuntimeError("Alarm.com pagination did not terminate — "
                               "check whether page/pageSize are the right params")
    return records


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

    total = 0
    for entity in ALARMDOTCOM["entities"]:
        records = fetch_entity(http, token, dealer_id, entity, args.limit)
        total += runner.land(bq_mod, bq, cfg, dataset, entity["name"], records,
                             entity["id_field"], ALARMDOTCOM["modified_field"], run_id)
    log.info("done: %d rows total", total)


if __name__ == "__main__":
    main()

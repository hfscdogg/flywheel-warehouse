"""iSolved timecards → raw_isolved. A trailing window of days every run.

Hours on the clock per employee per day, from the payroll system. The
warehouse had hours sold (D-Tools) and hours logged against jobs (Zoho CRM
meetings) but not the hours people were actually paid for, so job costing
stopped at equipment.

Auth: OAuth client-credentials grant, client id and secret from the client's
Secret Manager, sent as HTTP Basic (see Token).

Why a trailing window and not an increment: the API documents no
modified-time filter and a timecard is corrected after the fact (a missed
punch, an approval), so each run pulls the last ISOLVED lookback_days again.
Staging reads each day from the newest run that pulled it.

Why one day per request: see ISOLVED in lib/sources.py.

--full-refresh pulls from ISOLVED_HISTORY_START (client.env) instead.

client.env:
  ISOLVED_CLIENT_PATH_ID   required: the client id in the API path
  ISOLVED_LEGAL_ID         required: the legal-entity id in the API path
  ISOLVED_HISTORY_START    where --full-refresh starts (YYYY-MM-DD)
Env:
  ISOLVED_BASE_URL         optional override of the API host
  ISOLVED_LOOKBACK_DAYS    optional override of the nightly window
"""

import json
import logging
from datetime import date, datetime, timedelta, timezone

from ..lib import runner, util
from ..lib.sources import ISOLVED

log = logging.getLogger("flywheel.ingest.isolved")

CLIENT_ID_SECRET = "flywheel-isolved-client-id"
CLIENT_SECRET_SECRET = "flywheel-isolved-client-secret"
# Renew this long before the token's stated expiry.
RENEW_MARGIN_S = 60
# Used when the grant does not say how long its token lasts.
DEFAULT_TOKEN_LIFE_S = 600


class Token:
    """A bearer token from the client-credentials grant, renewed before it
    expires. The grant is cheap and has no lockout, so renewal is simply
    another grant; a refused one raises with the provider's reason."""

    def __init__(self, http, project_id, base_url, clock=None):
        import time
        self.http, self.project_id, self.base_url = http, project_id, base_url
        self.clock = clock or time.monotonic
        self.access, self.expires_at = None, 0.0

    def _secret(self, name):
        from ..lib import secret_store
        return secret_store.get(self.project_id, name)

    def _grant(self):
        resp = self.http.post(
            self.base_url + ISOLVED["token_path"],
            data={"grant_type": "client_credentials"},
            auth=(self._secret(CLIENT_ID_SECRET), self._secret(CLIENT_SECRET_SECRET)),
            headers={"Content-Type": "application/x-www-form-urlencoded"}, timeout=30)
        util.raise_for_status(resp, "iSolved token")
        try:
            body = resp.json()
        except ValueError:
            body = None
        if not isinstance(body, dict) or not body.get("access_token"):
            raise RuntimeError(
                "iSolved returned no access token; check "
                f"{CLIENT_ID_SECRET} and {CLIENT_SECRET_SECRET}")
        return body

    def invalidate(self):
        self.access = None

    def bearer(self):
        if self.access and self.clock() < self.expires_at - RENEW_MARGIN_S:
            return self.access
        body = self._grant()
        self.access = body["access_token"]
        try:
            life = float(body.get("expires_in") or DEFAULT_TOKEN_LIFE_S)
        except (TypeError, ValueError):
            life = DEFAULT_TOKEN_LIFE_S
        self.expires_at = self.clock() + life
        return self.access


def days_between(start, end):
    """Every date from start to end, both included, oldest first."""
    return [start + timedelta(days=n) for n in range((end - start).days + 1)]


def window(today, lookback_days, history_start=None):
    """The days a run pulls: the trailing window, or from history_start.

    Ends today. Today's timecards are part-way through the day, and tomorrow
    night's run replaces them along with the rest of the window.
    """
    start = history_start or today - timedelta(days=lookback_days)
    if start > today:
        raise ValueError(f"the window starts {start}, after today ({today})")
    return days_between(start, today)


def _get(http, token, url, params):
    """GET with the bearer token; one fresh grant if the token is refused."""
    for attempt in (0, 1):
        resp = http.get(url, headers={"Authorization": f"Bearer {token.bearer()}"},
                        params=params, timeout=60)
        if resp.status_code != 401 or attempt:
            return resp
        token.invalidate()
    return resp


def fetch_day(http, token, url, day, max_pages=None):
    """(employee records, pages read) for one day.

    Whether iSolved counts pages from 0 or 1 is not written down, and the
    Deluge fetch this follows asks for 0, 1 and 2 without saying. So reading
    starts at 0 and works either way: an empty page 0 is not the end (the
    API may count from 1), an empty page after that is; and a page identical
    to one already read is not counted twice. Page 1 repeating page 0 is the
    API counting from 1 and reading goes on; any later repeat is the API
    ignoring the page number and reading stops.
    """
    max_pages = max_pages or ISOLVED["max_pages"]
    iso = day.isoformat()
    records, seen = [], set()
    for page in range(max_pages):
        resp = _get(http, token, url, {
            "startDate": f"{iso}T00:00:00", "endDate": f"{iso}T23:59:59", "page": page})
        if resp.status_code == 204:
            if page == 0:
                continue
            return records, page
        util.raise_for_status(resp, f"iSolved timecards {iso}")
        body = resp.json()
        results = body.get("results") if isinstance(body, dict) else None
        if not results:
            if page == 0:
                continue
            return records, page
        if not isinstance(results, list):
            raise RuntimeError(f"iSolved timecards {iso}: 'results' is not a list")
        mark = json.dumps(results, sort_keys=True)
        if mark in seen:
            if page == 1:
                continue
            return records, page
        seen.add(mark)
        records.extend(r for r in results if isinstance(r, dict))
    raise RuntimeError(f"iSolved timecard paging for {iso} did not end after "
                       f"{max_pages} pages; check the page parameter")


def employee_name(record):
    first = str(record.get("employeeFirstName") or "").strip()
    last = str(record.get("employeeLastName") or "").strip()
    return f"{first} {last}".strip()


def timecard_rows(day, records):
    """Landing records for one day: the employee record as returned, under
    the day it was asked for. key is day|name; it only labels the row, since
    staging selects by run and day and never dedupes on it."""
    iso = day.isoformat()
    return [{"key": f"{iso}|{employee_name(r)}", "work_date": iso, "record": r}
            for r in records]


def day_row(day, records, pages):
    return {"work_date": day.isoformat(), "employees": len(records), "pages": pages}


def batches(days, size):
    return [days[i:i + size] for i in range(0, len(days), size)]


def parse_day(value, name):
    try:
        return date.fromisoformat(value)
    except (TypeError, ValueError):
        raise SystemExit(f"{name} must be a date as YYYY-MM-DD, not {value!r}")


def main():
    entity_names = [e["name"] for e in ISOLVED["entities"]]
    args, cfg, dataset, run_id = runner.setup("isolved", entity_names)
    import time

    from ..lib import bq as bq_mod
    from ..lib import web

    bq = bq_mod.client_for(cfg)
    # Landing tables before anything can fail, as the Alarm.com ingest does:
    # staging reads tables, and a source enabled but not yet credentialed
    # must not leave its model pointing at nothing.
    for name in entity_names:
        bq_mod.ensure_table(bq, cfg, dataset, name, bq_mod.LANDING_SCHEMA)

    client_id = cfg.env.get("ISOLVED_CLIENT_PATH_ID")
    legal_id = cfg.env.get("ISOLVED_LEGAL_ID")
    if not client_id or not legal_id:
        log.warning(
            "ISOLVED_CLIENT_PATH_ID and ISOLVED_LEGAL_ID are not both set in "
            "client.env: iSolved is enabled but not configured, so there is "
            "nothing to pull. See docs/phase-2-credentials.md section 2c.")
        return

    today = datetime.now(timezone.utc).date()
    history_start = None
    if args.full_refresh:
        history_start = parse_day(cfg.env.get("ISOLVED_HISTORY_START"),
                                  "ISOLVED_HISTORY_START (client.env), which "
                                  "--full-refresh needs,")
    lookback = int(util.env_or("ISOLVED_LOOKBACK_DAYS", ISOLVED["lookback_days"]))
    days = window(today, lookback, history_start)
    if args.limit:
        days = days[-args.limit:]   # smoke runs: the most recent N days

    base_url = util.env_or("ISOLVED_BASE_URL", ISOLVED["default_base_url"]).rstrip("/")
    url = base_url + ISOLVED["timecard_path"].format(client=client_id, legal=legal_id)
    http = web.session()
    token = Token(http, cfg.project_id, base_url)
    log.info("iSolved: %d days, %s to %s", len(days), days[0], days[-1])

    total = 0
    for batch in batches(days, ISOLVED["batch_days"]):
        cards, pulled = [], []
        for day in batch:
            records, pages = fetch_day(http, token, url, day)
            cards.extend(timecard_rows(day, records))
            pulled.append(day_row(day, records, pages))
            time.sleep(ISOLVED["pause_s"])
        # Timecards first. Staging reads a day from the run its day row
        # names, so a day row without its timecards would empty that day;
        # the other way round only leaves the previous pull in place.
        total += runner.land(bq_mod, bq, cfg, dataset, "timecards", cards,
                             "key", None, run_id)
        runner.land(bq_mod, bq, cfg, dataset, "timecard_days", pulled,
                    "work_date", None, run_id)
    log.info("done: %d employee-days landed over %d days", total, len(days))


if __name__ == "__main__":
    main()

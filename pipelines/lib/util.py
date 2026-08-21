"""Pure helpers — no GCP or network imports, unit-testable with stdlib only."""

import logging
import re
from datetime import datetime, timezone
from pathlib import Path

_ENV_LINE = re.compile(r'^([A-Z][A-Z0-9_]*)="([^"]*)"')
_VAR_REF = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")

log = logging.getLogger("flywheel.ingest")

# Enough to carry a provider error payload; short enough that an HTML error
# page does not bury the rest of the run.
MAX_ERROR_BODY = 2000


def parse_client_env(path):
    """Parse a clients/<slug>/client.env file into a dict.

    Not a shell: only KEY="value" lines are read; ${VAR} references resolve
    against earlier keys (unresolvable refs are left verbatim). Comments and
    anything else are ignored.
    """
    out = {}
    for line in Path(path).read_text().splitlines():
        m = _ENV_LINE.match(line.strip())
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        out[key] = _VAR_REF.sub(lambda r: out.get(r.group(1), r.group(0)), val)
    return out


def utcnow_iso():
    return datetime.now(timezone.utc).isoformat()


def parse_ts(value):
    """Parse an ISO-8601 timestamp (offset or 'Z') to an aware datetime."""
    if value is None:
        return None
    return datetime.fromisoformat(str(value).replace("Z", "+00:00"))


def get_path(record, dotted):
    """record["MetaData"]["LastUpdatedTime"] via 'MetaData.LastUpdatedTime'."""
    cur = record
    for part in dotted.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
    return cur


def build_row(record, id_field, modified_field, run_id, loaded_at):
    """Wrap one source record into the landing-table row shape.

    The full record lands as JSON in `payload`; the loader extracts only the
    metadata columns. Dedup/latest-record logic belongs in staging (Phase 3).
    """
    return {
        "payload": record,
        "_source_id": None if get_path(record, id_field) is None
        else str(get_path(record, id_field)),
        "_modified_at": get_path(record, modified_field),
        "_loaded_at": loaded_at,
        "_run_id": run_id,
    }


def max_modified(records, modified_field):
    """Largest source-side modified timestamp in a batch (ISO string), or None."""
    best = None
    for r in records:
        ts = parse_ts(get_path(r, modified_field))
        if ts is not None and (best is None or ts > best):
            best = ts
    return best.isoformat() if best else None


def raise_for_status(resp, context=""):
    """`resp.raise_for_status()`, but log the response body first.

    Source APIs put the actual reason for a refusal in the body — an Intuit
    403 carries a fault code and message there — and `raise_for_status`
    discards it, so a failed run reports a bare status code and nothing
    about why. This is the difference between "403" and "403, and here is
    the reason".

    Safe to log: every source sends its credentials in headers or a POST form
    body, never in the query string, so the URL holds nothing sensitive. The
    body is truncated so a stray error page cannot flood the log.

    Returns the response unchanged when it is not an error, so this can wrap
    a call inline.
    """
    if resp.status_code < 400:
        return resp
    body = (resp.text or "").strip() or "<empty body>"
    if len(body) > MAX_ERROR_BODY:
        body = f"{body[:MAX_ERROR_BODY]}… [truncated, {len(body)} bytes total]"
    log.error("HTTP %d for %s%s — response body: %s", resp.status_code, resp.url,
              f" [{context}]" if context else "", body)
    resp.raise_for_status()
    return resp

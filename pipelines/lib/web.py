"""HTTP session with retry/backoff for source-system APIs."""

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from .util import check_retry_after


class CappedRetry(Retry):
    """Retry that fails instead of sleeping on a long Retry-After
    (util.RETRY_AFTER_CAP_SECONDS, or the session's own retry_after_cap).
    urllib3 builds each next attempt through new(), which carries the cap
    over, so it holds across every retry."""

    retry_after_cap = None

    def new(self, **kw):
        nxt = super().new(**kw)
        nxt.retry_after_cap = self.retry_after_cap
        return nxt

    def get_retry_after(self, response):
        return check_retry_after(super().get_retry_after(response),
                                 response.status, getattr(response, "url", None),
                                 cap=self.retry_after_cap)


def session(retry_after_cap=None):
    """A session that retries 429s and 5xx with backoff.

    retry_after_cap: the longest Retry-After to sleep through, in seconds.
    Leave it unset for the shared 300s cap. Raise it only for a source whose
    normal throttle answer is a long wait and whose job has the time budget
    to absorb it (Zoho Billing: 1800s, inside a 240-minute detail budget).
    """
    s = requests.Session()
    retry = CappedRetry(
        total=5,
        backoff_factor=2,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET", "POST"],
        respect_retry_after_header=True,
    )
    retry.retry_after_cap = retry_after_cap
    s.mount("https://", HTTPAdapter(max_retries=retry))
    return s

"""HTTP session with retry/backoff for source-system APIs."""

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from .util import check_retry_after


class CappedRetry(Retry):
    """Retry that fails instead of sleeping on a long Retry-After
    (util.RETRY_AFTER_CAP_SECONDS). urllib3 builds each next attempt with
    type(self), so the cap holds across every retry."""

    def get_retry_after(self, response):
        return check_retry_after(super().get_retry_after(response),
                                 response.status, getattr(response, "url", None))


def session():
    s = requests.Session()
    retry = CappedRetry(
        total=5,
        backoff_factor=2,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET", "POST"],
        respect_retry_after_header=True,
    )
    s.mount("https://", HTTPAdapter(max_retries=retry))
    return s

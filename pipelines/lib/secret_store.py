"""Secret Manager access (imports google-cloud-secret-manager).

All source credentials live in the client's own project — GitHub holds no
client secrets (docs/trust.md). ingest-writer has secretAccessor on the
flywheel-* secrets, and secretVersionAdder on the QBO refresh token only.
"""

from google.cloud import secretmanager

_client = None


def _sm():
    global _client
    if _client is None:
        _client = secretmanager.SecretManagerServiceClient()
    return _client


def get(project_id, name):
    path = f"projects/{project_id}/secrets/{name}/versions/latest"
    resp = _sm().access_secret_version(name=path)
    return resp.payload.data.decode("utf-8").strip()


def add_version(project_id, name, value):
    _sm().add_secret_version(
        parent=f"projects/{project_id}/secrets/{name}",
        payload={"data": value.encode("utf-8")},
    )

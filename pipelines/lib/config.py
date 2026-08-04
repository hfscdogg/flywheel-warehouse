"""Client configuration for pipelines — same client.env files as scripts/."""

from pathlib import Path

from .util import parse_client_env

REPO_ROOT = Path(__file__).resolve().parents[2]

REQUIRED = (
    "CLIENT_SLUG", "GCP_PROJECT_ID", "BQ_LOCATION",
    "DATASETS_RAW", "DATASET_STAGING", "DATASET_MARTS",
)


class ClientConfig:
    def __init__(self, env):
        for key in REQUIRED:
            if not env.get(key):
                raise ValueError(f"client.env missing required variable: {key}")
        self.slug = env["CLIENT_SLUG"]
        self.project_id = env["GCP_PROJECT_ID"]
        self.bq_location = env["BQ_LOCATION"]
        self.raw_datasets = env["DATASETS_RAW"].split()
        self.env = env

    def raw_dataset_for(self, source):
        """'zoho' -> 'raw_zoho' if the client has that source enabled, else None."""
        name = f"raw_{source}"
        return name if name in self.raw_datasets else None


def load_client(slug):
    path = REPO_ROOT / "clients" / slug / "client.env"
    if not path.is_file():
        raise FileNotFoundError(f"unknown client '{slug}' (no {path})")
    return ClientConfig(parse_client_env(path))

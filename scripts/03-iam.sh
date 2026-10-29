#!/usr/bin/env bash
# 03-iam.sh <client-slug> — every IAM binding, in one auditable place.
#
# The trust surface (docs/trust.md) is defined here:
#   hermes-reader : jobUser (project) + dataViewer on marts — and on staging
#                   too when the client's AGENT_SCOPE is "wide" (Tier 2b).
#                   Under "narrow" the staging grant is REVOKED if present.
#   ingest-<src>  : jobUser (project) + dataEditor on raw_<src> ONLY
#   transform-writer : jobUser (project) + dataViewer on every raw dataset
#                   (and the GA4 export) + dataEditor on staging and marts
#   warehouse-reader : jobUser (project) + dataViewer on every dataset (and
#                   the GA4 export). Writes nothing; probe.yml runs as it.
#   READER_USERS  : jobUser (project) + dataViewer on every dataset (and the
#                   GA4 export). The client's people; read-only.
#   ADMIN_USER    : serviceAccountTokenCreator on the hermes-reader SA
#
# Connector secrets and which workflow may act as which account are
# 05-ingestion-infra.sh. The retired single ingest-writer gets nothing here;
# 11-retire-ingest-writer.sh strips what it still holds.
#
# hermes-reader deliberately gets NOTHING on raw_*, ever. Staging is the
# client's call (AGENT_SCOPE); raw is not.
#
# Bindings run serially: concurrent policy writes hit etag conflicts. Both
# 'gcloud ... add-iam-policy-binding' and 'bq add-iam-policy-binding' are
# no-ops when the binding already exists, so this script is re-runnable.
# shellcheck disable=SC2086  # $BQ is intentionally word-split
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0"
load_client "$1"
require_cmd gcloud bq python3

# grant_dataset_role and revoke_dataset_role live in lib/common.sh.

info "IAM bindings for '$CLIENT_SLUG' in $GCP_PROJECT_ID"

info "hermes-reader: query jobs at project level"
run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:$SA_HERMES_READER_EMAIL" \
  --role=roles/bigquery.jobUser --condition=None --format=none --quiet

info "hermes-reader: read access on $DATASETS_AGENT (AGENT_SCOPE=$AGENT_SCOPE)"
for ds in $DATASETS_AGENT; do
  grant_dataset_role "$SA_HERMES_READER_EMAIL" roles/bigquery.dataViewer "$ds"
done

# Narrowing is a revoke, not only a grant. A client moving from wide to
# narrow had staging's grant left in place: client.env, the endpoint's table
# list and the docs all said marts only, while BigQuery still let the agent
# read staging. So every dataset outside DATASETS_AGENT loses whatever
# hermes-reader holds on it: every dataset in the project, including ones
# client.env does not name. raw_* never should hold one, but is checked too
# rather than trusted.
if is_dry_run; then
  AGENT_OUTSIDE="$ALL_DATASETS $GA4_EXPORT_DATASET"
else
  AGENT_OUTSIDE="$(project_datasets)"
  [ -n "$AGENT_OUTSIDE" ] || die "could not list the datasets in $GCP_PROJECT_ID"
fi
for ds in $AGENT_OUTSIDE; do
  case " $DATASETS_AGENT " in
    *" $ds "*) : ;;
    *) revoke_dataset_member "$SA_HERMES_READER_EMAIL" "$ds" ;;
  esac
done

grant_job_user() {
  run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:$1" \
    --role=roles/bigquery.jobUser --condition=None --format=none --quiet
}

# Each ingest account writes its own raw dataset and nothing else. A bug or a
# compromise in the Zoho connector cannot touch QuickBooks' tables, staging or
# marts.
for src in $INGEST_SOURCES; do
  email="$(ingest_sa_email "$src")"
  info "$(ingest_sa_name "$src"): query jobs + write raw_$src only"
  grant_job_user "$email"
  grant_dataset_role "$email" roles/bigquery.dataEditor "raw_$src"
done

# The transform reads every raw dataset and rebuilds staging and marts. The
# GA4 export is written by Google, outside DATASETS_RAW, and read only through
# the view raw_ga4.events, which runs with the querying identity's own access,
# so the transform needs to read the export too. hermes-reader gets no grant
# there, as on raw.
info "$SA_TRANSFORM: read raw, write $DATASET_STAGING and $DATASET_MARTS"
grant_job_user "$SA_TRANSFORM_EMAIL"
for ds in $DATASETS_RAW $GA4_EXPORT_DATASET; do
  grant_dataset_role "$SA_TRANSFORM_EMAIL" roles/bigquery.dataViewer "$ds"
done
for ds in $DATASET_STAGING $DATASET_MARTS; do
  grant_dataset_role "$SA_TRANSFORM_EMAIL" roles/bigquery.dataEditor "$ds"
done

# probe.yml answers the questions the agent cannot (raw payload shapes), so
# it reads everything. It writes nothing: a statement that slipped past the
# probe's own check would still be refused by BigQuery.
info "$SA_PROBE: read every dataset, write none"
grant_job_user "$SA_PROBE_EMAIL"
for ds in $ALL_DATASETS $GA4_EXPORT_DATASET; do
  grant_dataset_role "$SA_PROBE_EMAIL" roles/bigquery.dataViewer "$ds"
done

# The client's own people who ask the warehouse questions (READER_USERS,
# Tier 1r). Read on every dataset, raw and the GA4 export included, as
# warehouse-reader has; write on none. jobUser runs queries and nothing else:
# it creates no table a query could write to, and dataViewer refuses every
# write. Removing someone from READER_USERS does not revoke them: that is
# 99-teardown.sh --revoke-reader=<email>.
for reader in $READER_USERS; do
  info "$reader: read every dataset, write none"
  run gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="user:$reader" \
    --role=roles/bigquery.jobUser --condition=None --format=none --quiet
  for ds in $ALL_DATASETS $GA4_EXPORT_DATASET; do
    grant_dataset_role "$reader" roles/bigquery.dataViewer "$ds"
  done
done

# Project Owner does NOT include token creation. This is what lets ADMIN_USER
# impersonate hermes-reader — for 90-verify's smoke test, and for keyless
# agent auth.
info "$ADMIN_USER: impersonation rights on hermes-reader"
run gcloud iam service-accounts add-iam-policy-binding "$SA_HERMES_READER_EMAIL" \
  --project "$GCP_PROJECT_ID" \
  --member="user:$ADMIN_USER" \
  --role=roles/iam.serviceAccountTokenCreator --format=none --quiet

info "IAM done."

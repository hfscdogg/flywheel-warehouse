#!/usr/bin/env bash
# 92-iam-snapshot.sh <client-slug> <out-dir> — READ-ONLY dump of who can do
# what in the client's project, in a form two dumps can be diffed in.
#
# Writes:
#   <out-dir>/grants.txt          one sorted line per grant or trust setting:
#                                 project policy, every service account (and
#                                 who may act as it), every dataset's access
#                                 entries, every secret, bucket and Cloud Run
#                                 service policy, every WIF pool and provider,
#                                 custom roles. No etags, no timestamps, so
#                                 `diff -u before/grants.txt after/grants.txt`
#                                 shows exactly what changed.
#   <out-dir>/project-policy.json the project IAM policy as gcloud returns it,
#                                 without its etag.
#
# Only list, describe and get-iam-policy calls. Never reads a secret's value.
# The output names accounts, users and groups, not customers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 2 ] || usage_and_exit "$0 <out-dir>"
load_client "$1"
OUT="$2"
RUN_REGION="${RUN_REGION:-us-east4}"

if is_dry_run; then
  info "[dry-run] would write $OUT/grants.txt and $OUT/project-policy.json (read-only)"
  exit 0
fi
require_cmd gcloud bq python3
mkdir -p "$OUT"

# policy_lines <prefix>: an IAM policy (JSON) on stdin → "<prefix> <role> <member>"
# per member, with " if <condition title>: <expression>" when conditional.
policy_lines() {
  PREFIX="$1" python3 -c '
import json, os, sys
try:
    policy = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for b in policy.get("bindings", []):
    c = b.get("condition")
    cond = " if %s: %s" % (c.get("title", ""), c.get("expression", "")) if c else ""
    for m in b.get("members", []):
        print("%s %s %s%s" % (os.environ["PREFIX"], b["role"], m, cond))
'
}

info "Snapshotting $GCP_PROJECT_ID to $OUT"
{
  gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json | policy_lines "project"

  for sa in $(gcloud iam service-accounts list --project "$GCP_PROJECT_ID" --format='value(email)'); do
    d="$(gcloud iam service-accounts describe "$sa" --project "$GCP_PROJECT_ID" --format='value(disabled)')"
    printf 'account %s disabled=%s\n' "$sa" "${d:-False}"
    n="$(gcloud iam service-accounts keys list --iam-account "$sa" --project "$GCP_PROJECT_ID" \
      --managed-by=user --format='value(name)' | wc -l | tr -d ' ')"
    printf 'account %s user-managed-keys=%s\n' "$sa" "$n"
    gcloud iam service-accounts get-iam-policy "$sa" --project "$GCP_PROJECT_ID" --format=json \
      | policy_lines "account-policy $sa"
  done

  for ds in $(project_datasets); do
    # shellcheck disable=SC2086  # $BQ is intentionally word-split
    $BQ show --format=prettyjson "$GCP_PROJECT_ID:$ds" | DS="$ds" python3 -c '
import json, os, sys
for e in json.load(sys.stdin).get("access", []):
    if "view" in e or "routine" in e or "dataset" in e:
        kind = "view" if "view" in e else "routine" if "routine" in e else "dataset"
        print("dataset %s authorized-%s %s" % (os.environ["DS"], kind, json.dumps(e[kind], sort_keys=True)))
        continue
    who = [k + ":" + str(v) for k, v in sorted(e.items()) if k != "role"]
    print("dataset %s %s %s" % (os.environ["DS"], e.get("role", ""), " ".join(who)))
'
  done

  for s in $(gcloud secrets list --project "$GCP_PROJECT_ID" --format='value(name.basename())'); do
    printf 'secret %s exists\n' "$s"
    gcloud secrets get-iam-policy "$s" --project "$GCP_PROJECT_ID" --format=json | policy_lines "secret $s"
  done

  for b in $(gcloud storage buckets list --project "$GCP_PROJECT_ID" --format='value(name)'); do
    gcloud storage buckets get-iam-policy "gs://$b" --format=json | policy_lines "bucket $b"
  done

  for s in $(gcloud run services list --project "$GCP_PROJECT_ID" --region "$RUN_REGION" \
      --format='value(metadata.name)'); do
    printf 'run %s runs-as %s\n' "$s" "$(gcloud run services describe "$s" --project "$GCP_PROJECT_ID" \
      --region "$RUN_REGION" --format='value(spec.template.spec.serviceAccountName)')"
    gcloud run services get-iam-policy "$s" --project "$GCP_PROJECT_ID" --region "$RUN_REGION" \
      --format=json | policy_lines "run $s"
  done

  for pool in $(gcloud iam workload-identity-pools list --project "$GCP_PROJECT_ID" \
      --location=global --format='value(name.basename())'); do
    printf 'wif-pool %s\n' "$pool"
    gcloud iam workload-identity-pools providers list --project "$GCP_PROJECT_ID" --location=global \
        --workload-identity-pool="$pool" --format=json | POOL="$pool" python3 -c '
import json, os, sys
for p in json.load(sys.stdin) or []:
    name = "%s/%s" % (os.environ["POOL"], p["name"].rsplit("/", 1)[1])
    print("wif-provider %s state=%s disabled=%s" % (name, p.get("state"), p.get("disabled", False)))
    print("wif-provider %s issuer=%s" % (name, (p.get("oidc") or {}).get("issuerUri", "")))
    print("wif-provider %s condition=%s" % (name, p.get("attributeCondition", "")))
    for k, v in sorted((p.get("attributeMapping") or {}).items()):
        print("wif-provider %s map %s=%s" % (name, k, v))
'
  done

  for r in $(gcloud iam roles list --project "$GCP_PROJECT_ID" --format='value(name.basename())'); do
    printf 'custom-role %s permissions=%s\n' "$r" \
      "$(gcloud iam roles describe "$r" --project "$GCP_PROJECT_ID" --format='value(includedPermissions)')"
  done
} | LC_ALL=C sort > "$OUT/grants.txt"

gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json \
  | python3 -c 'import json, sys; p = json.load(sys.stdin); p.pop("etag", None); print(json.dumps(p, indent=2, sort_keys=True))' \
  > "$OUT/project-policy.json"

info "Wrote $OUT/grants.txt ($(wc -l < "$OUT/grants.txt" | tr -d ' ') lines) and $OUT/project-policy.json"

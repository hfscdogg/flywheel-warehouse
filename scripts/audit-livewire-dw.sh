#!/usr/bin/env bash
# audit-livewire-dw.sh — READ-ONLY inventory of who can do what in livewire-dw.
#
# Run in Cloud Shell as henry@getlivewire.com:  bash audit-livewire-dw.sh
# It writes audit-livewire-dw.txt next to itself and changes nothing.
#
# Every command here is a list/describe/get-iam-policy. It never reads a
# secret's VALUE (no `secrets versions access`), only who may read it.
# The output names service accounts and users, not customers; it is safe to
# paste back into the Claude session.
set -uo pipefail
P=livewire-dw
REGION=us-east4
OUT="$(dirname "$0")/audit-livewire-dw.txt"
exec > >(tee "$OUT") 2>&1
h() { printf '\n===== %s =====\n' "$*"; }

h "service accounts"
gcloud iam service-accounts list --project "$P" \
  --format="table(email,displayName,disabled)"

h "user-managed keys per service account (should be none: the design is keyless)"
for sa in $(gcloud iam service-accounts list --project "$P" --format="value(email)"); do
  n=$(gcloud iam service-accounts keys list --iam-account "$sa" --project "$P" \
        --managed-by=user --format="value(name)" | wc -l)
  echo "$sa  user-managed keys: $n"
done

h "project-level IAM (role -> members, with conditions)"
gcloud projects get-iam-policy "$P" --format=json | python3 -c '
import json,sys
for b in json.load(sys.stdin).get("bindings",[]):
    cond = b.get("condition",{}).get("expression","")
    for m in b["members"]:
        print(b["role"].ljust(55), m, ("   IF " + cond) if cond else "")'

h "who may act as / impersonate each service account"
for sa in $(gcloud iam service-accounts list --project "$P" --format="value(email)"); do
  echo "--- $sa"
  gcloud iam service-accounts get-iam-policy "$sa" --project "$P" --format=json | python3 -c '
import json,sys
for b in json.load(sys.stdin).get("bindings",[]):
    for m in b["members"]: print(" ", b["role"].ljust(45), m)'
done

h "workload identity pools and providers (the GitHub trust condition)"
for pool in $(gcloud iam workload-identity-pools list --project "$P" --location=global --format="value(name.basename())"); do
  echo "--- pool $pool"
  gcloud iam workload-identity-pools providers list --project "$P" --location=global \
    --workload-identity-pool="$pool" \
    --format="yaml(name.basename(),state,disabled,attributeCondition,attributeMapping,oidc.issuerUri)"
done

h "secrets and who may read or write them (names and policies only, never values)"
for s in $(gcloud secrets list --project "$P" --format="value(name.basename())"); do
  echo "--- $s"
  gcloud secrets get-iam-policy "$s" --project "$P" --format=json | python3 -c '
import json,sys
for b in json.load(sys.stdin).get("bindings",[]):
    for m in b["members"]: print(" ", b["role"].ljust(45), m)'
done

h "BigQuery dataset access entries"
for ds in $(bq ls --project_id="$P" --format=json | python3 -c 'import json,sys;[print(d["datasetReference"]["datasetId"]) for d in json.load(sys.stdin)]'); do
  echo "--- $ds"
  bq show --format=json "$P:$ds" | python3 -c '
import json,sys
for e in json.load(sys.stdin).get("access",[]):
    who = e.get("userByEmail") or e.get("groupByEmail") or e.get("specialGroup") or e.get("domain") or ("view:"+json.dumps(e["view"]) if "view" in e else json.dumps(e))
    print(" ", e.get("role","(authorized view)").ljust(12), who)'
done

h "storage buckets and their IAM"
for b in $(gcloud storage buckets list --project "$P" --format="value(name)"); do
  echo "--- gs://$b"
  gcloud storage buckets get-iam-policy "gs://$b" --format=json | python3 -c '
import json,sys
for b in json.load(sys.stdin).get("bindings",[]):
    for m in b["members"]: print(" ", b["role"].ljust(45), m)'
done

h "Cloud Run services: runtime identity and invoker policy"
for s in $(gcloud run services list --project "$P" --region "$REGION" --format="value(metadata.name)"); do
  echo "--- $s runs as: $(gcloud run services describe "$s" --project "$P" --region "$REGION" --format='value(spec.template.spec.serviceAccountName)')"
  gcloud run services get-iam-policy "$s" --project "$P" --region "$REGION" --format=json | python3 -c '
import json,sys
for b in json.load(sys.stdin).get("bindings",[]):
    for m in b["members"]: print(" ", b["role"].ljust(45), m)'
done

h "custom roles"
gcloud iam roles list --project "$P" --format="table(name.basename(),title,stage)"
for r in $(gcloud iam roles list --project "$P" --format="value(name.basename())"); do
  echo "--- $r: $(gcloud iam roles describe "$r" --project "$P" --format='value(includedPermissions)')"
done

h "BigQuery Data Transfer configs (Google Ads) and who owns them"
bq ls --transfer_config --transfer_location=us --project_id="$P" --format=prettyjson 2>/dev/null \
  | python3 -c 'import json,sys
try:
  for t in json.load(sys.stdin): print(" ", t.get("displayName"), "|", t.get("dataSourceId"), "| dest:", t.get("destinationDatasetId"), "| owner:", t.get("ownerInfo",{}).get("email"))
except Exception as e: print("  (none or not readable)")'

h "done"
echo "Wrote $OUT"

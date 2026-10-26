#!/usr/bin/env bash
# Read-only. Step 9, option 1: the non-Hermes checks from 90-verify.sh, plus step 8 evidence.
P=livewire-dw; F=0
ok(){ echo "PASS  $*"; }; bad(){ echo "FAIL  $*"; F=$((F+1)); }
SAS="ingest-zoho ingest-zohobilling ingest-dtools ingest-qbo ingest-vendor ingest-alarmdotcom transform-writer warehouse-reader"
INGEST="ingest-zoho ingest-zohobilling ingest-dtools ingest-qbo ingest-vendor ingest-alarmdotcom"
DS="raw_zoho raw_zohobilling raw_dtools raw_qbo raw_vendor raw_alarmdotcom raw_ga4 raw_google_ads staging marts"
declare -A ACL
for ds in $DS analytics_285482813; do ACL[$ds]="$(bq show --format=json "$P:$ds" 2>/dev/null)"; done

echo "== 1. datasets exist in US"
for ds in $DS; do
  L=$(printf '%s' "${ACL[$ds]}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["location"])' 2>/dev/null)
  [ "$L" = US ] && ok "dataset $ds in US" || bad "dataset $ds missing or in '${L:-none}'"
done

echo "== 2. pipeline accounts exist"
for s in $SAS; do
  gcloud iam service-accounts describe "$s@$P.iam.gserviceaccount.com" --project $P >/dev/null 2>&1 \
    && ok "account $s exists" || bad "account $s missing"
done

echo "== 3. no ingest account on staging or marts"
for ds in staging marts; do
  [ -z "${ACL[$ds]}" ] && { bad "could not read access on $ds"; continue; }
  for s in $INGEST; do
    printf '%s' "${ACL[$ds]}" | grep -q "\"$s@" && bad "$s bound on $ds" || ok "$s has no grant on $ds"
  done
done

echo "== 3b. project jobUser"
J=$(gcloud projects get-iam-policy $P --flatten='bindings[].members' --filter='bindings.role=roles/bigquery.jobUser' --format='value(bindings.members)')
for s in $SAS; do
  printf '%s\n' "$J" | grep -q "serviceAccount:$s@" && ok "$s has jobUser" || bad "$s missing jobUser"
done

echo "== step 8: ingest-writer retired"
D=$(gcloud iam service-accounts describe "ingest-writer@$P.iam.gserviceaccount.com" --project $P --format='value(disabled)')
case "$D" in True|true) ok "ingest-writer is disabled";; *) bad "ingest-writer disabled='$D'";; esac
printf '%s\n' "$J" | grep -q "ingest-writer@" && bad "ingest-writer still has jobUser" || ok "ingest-writer has no jobUser"
for ds in $DS analytics_285482813; do
  [ -z "${ACL[$ds]}" ] && { bad "could not read access on $ds"; continue; }
  printf '%s' "${ACL[$ds]}" | grep -q "ingest-writer@" && bad "ingest-writer still bound on $ds" || ok "ingest-writer has no grant on $ds"
done
W=$(gcloud iam service-accounts get-iam-policy "ingest-writer@$P.iam.gserviceaccount.com" --project $P --format=json)
printf '%s' "$W" | grep -q workloadIdentityUser && bad "ingest-writer still has a WIF binding" || ok "ingest-writer has no WIF binding"

echo; echo "failures: $F"

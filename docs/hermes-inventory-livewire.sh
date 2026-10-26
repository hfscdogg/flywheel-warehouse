#!/usr/bin/env bash
# Read-only. Lists every Hermes resource in livewire-dw before decommissioning.
# Changes nothing. Run from Cloud Shell as the project owner.
P=livewire-dw; R=us-east4; REPO=hfscdogg/flywheel-warehouse
SAS="hermes-reader endpoint-deployer endpoint-builder"
h(){ echo; echo "== $*"; }

h "1. Cloud Run service hermes-mcp ($R)"
gcloud run services describe hermes-mcp --region $R --project $P \
  --format='value(status.url,spec.template.spec.serviceAccountName,status.latestReadyRevisionName)' 2>&1 | head -3

h "1b. requests to hermes-mcp, last 14 days (newest 10)"
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="hermes-mcp" AND httpRequest.status>0' \
  --project $P --freshness=14d --limit=10 --format='value(timestamp,httpRequest.status,httpRequest.userAgent)' 2>&1

h "2. accounts: disabled? user-managed keys?"
for s in $SAS; do
  e="$s@$P.iam.gserviceaccount.com"
  d=$(gcloud iam service-accounts describe "$e" --project $P --format='value(disabled)' 2>&1)
  k=$(gcloud iam service-accounts keys list --iam-account "$e" --managed-by=user --format='value(name)' 2>/dev/null | wc -l)
  echo "$s  disabled=${d:-False}  user_keys=$k"
done

h "3. who can act as each account (its own IAM policy)"
for s in $SAS; do
  echo "-- $s"
  gcloud iam service-accounts get-iam-policy "$s@$P.iam.gserviceaccount.com" --project $P \
    --flatten='bindings[].members' --format='value(bindings.role,bindings.members)' 2>&1
done

h "4. project roles held by each account"
for s in $SAS; do
  echo "-- $s"
  gcloud projects get-iam-policy $P --flatten='bindings[].members' \
    --filter="bindings.members:serviceAccount:$s@" --format='value(bindings.role)' 2>&1
done

h "5. dataset grants to hermes-reader"
for ds in $(bq ls --project_id=$P --format=json | python3 -c 'import sys,json;[print(d["datasetReference"]["datasetId"]) for d in json.load(sys.stdin)]'); do
  bq show --format=json "$P:$ds" | python3 -c '
import sys,json; ds=sys.argv[1]
for e in json.load(sys.stdin).get("access",[]):
    if "hermes-reader@" in json.dumps(e): print(ds, e.get("role"))' "$ds"
done

h "6. secret hermes-endpoint-token: versions and access"
gcloud secrets versions list hermes-endpoint-token --project $P --format='value(name,state,createTime)' 2>&1
gcloud secrets get-iam-policy hermes-endpoint-token --project $P --flatten='bindings[].members' \
  --format='value(bindings.role,bindings.members)' 2>&1

h "7. Hermes grants on any other secret"
for sec in $(gcloud secrets list --project $P --format='value(name)'); do
  gcloud secrets get-iam-policy "$sec" --project $P --flatten='bindings[].members' --format='value(bindings.role,bindings.members)' 2>/dev/null \
    | grep -E 'hermes-reader@|endpoint-(deployer|builder)@' | sed "s|^|$sec  |"
done

h "8. build-side leftovers"
gcloud iam roles describe flywheelSourceBucketLister --project $P --format='value(name,includedPermissions)' 2>&1 | head -2
gcloud storage buckets get-iam-policy gs://run-sources-$P-$R --format=json 2>&1 | grep -E 'endpoint-(deployer|builder)@' || echo "(no endpoint-* grants on gs://run-sources-$P-$R, or bucket absent)"
gcloud artifacts repositories list --project $P --location $R --format='value(name,sizeBytes)' 2>&1

h "9. GitHub side"
gh variable list --repo $REPO 2>&1 | grep -i -E 'DEPLOYER|HERMES' || echo "(no deployer/hermes variables)"
gh api repos/$REPO/environments --jq '.environments[].name' 2>&1
echo; echo "inventory done (nothing was changed)"

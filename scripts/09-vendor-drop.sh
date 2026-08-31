#!/usr/bin/env bash
# 09-vendor-drop.sh <client-slug> [grant <email>]
#
# Creates the vendor report drop bucket and, optionally, grants an employee
# upload access to it. Monitoring vendors send reports rather than exposing
# APIs, so someone has to put the file somewhere; this makes that a browser
# drag-and-drop instead of a command line.
#
#   ./scripts/09-vendor-drop.sh livewire                      # create + show folders
#   ./scripts/09-vendor-drop.sh livewire grant amy@client.com # let Amy upload
#
# The grant is objectCreator + objectViewer on THIS BUCKET ONLY: the grantee
# can add files and see what they added, and has no access to BigQuery, the
# warehouse, or anything else in the project.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_and_exit "$0 (actions: [none] | grant <email>)"
load_client "$1"
ACTION="${2:-create}"
require_cmd gcloud gsutil

BUCKET="${VENDOR_DROP_BUCKET:-${GCP_PROJECT_ID}-vendor-drops}"
# Keep this list in step with pipelines/lib/tabular.FORMATS.
DROP_PREFIXES="securitycentral/allaccounts securitycentral/customercount \
alarmdotcom/customerlist parasol/invoice"

case "$ACTION" in
  create)
    info "Drop bucket gs://$BUCKET"
    if probe gsutil ls -b "gs://$BUCKET"; then
      log "  bucket exists"
    else
      run gsutil mb -p "$GCP_PROJECT_ID" -l "$BQ_LOCATION" -b on "gs://$BUCKET"
      run gsutil label ch -l "managed-by:$LABEL_MANAGED_BY" -l "env:$LABEL_ENV" "gs://$BUCKET"
    fi

    info "$SA_INGEST_WRITER: read and archive uploads"
    run gsutil iam ch \
      "serviceAccount:$SA_INGEST_WRITER_EMAIL:roles/storage.objectAdmin" \
      "gs://$BUCKET"

    info "Folder placeholders (a bucket has no real folders; these make the"
    info "upload targets visible in the console)"
    # A placeholder is cosmetic and its failure is not fatal, but it is never
    # silent: this loop used to discard the error and log the folder anyway,
    # which printed four confident lines over an empty bucket. A file uploaded
    # outside these prefixes is not scanned and never reaches the warehouse,
    # so "the folder is missing" has to reach the operator.
    placeholders_failed=0
    for p in $DROP_PREFIXES; do
      if is_dry_run; then
        log "[dry-run] create gs://$BUCKET/$p/ placeholder"
        continue
      fi
      if err=$(printf '\n' | gsutil cp - "gs://$BUCKET/$p/.keep" 2>&1); then
        log "  gs://$BUCKET/$p/"
      else
        placeholders_failed=1
        warn "could not create gs://$BUCKET/$p/.keep"
        printf '%s\n' "$err" | sed 's/^/    /' >&2
      fi
    done

    if [ "$placeholders_failed" = 1 ]; then
      log ""
      warn "Some folders were not created. Make them by hand in the console"
      warn "with 'Create folder' — the names above, exactly. An upload that"
      warn "lands anywhere else is never read."
    fi

    log ""
    info "What is actually in the bucket now"
    gsutil ls "gs://$BUCKET/**" 2>/dev/null | sed 's/^/  /' || log "  (empty)"

    log ""
    info "Upload here (browser): https://console.cloud.google.com/storage/browser/$BUCKET"
    log "  Security Central 'All Accounts' (SCAN export, has addresses)"
    log "    -> $BUCKET/securitycentral/allaccounts/"
    log "  Security Central 'Customer Count' (weekly emailed CSV, status only)"
    log "    -> $BUCKET/securitycentral/customercount/"
    log "  Alarm.com 'Custom List' (dealer site export, .csv)"
    log "    -> $BUCKET/alarmdotcom/customerlist/"
    log "  Parasol monthly invoice (.pdf — the invoice is the roster)"
    log "    -> $BUCKET/parasol/invoice/"
    log ""
    log "The ingest-vendordrop workflow picks up new files daily and archives"
    log "them under processed/. To let an employee upload:"
    log "  ./scripts/09-vendor-drop.sh $CLIENT_SLUG grant <their-email>"
    ;;

  grant)
    GRANTEE="${3:-}"
    [ -n "$GRANTEE" ] || die "usage: $0 $CLIENT_SLUG grant <email>"
    info "Granting $GRANTEE upload access to gs://$BUCKET (this bucket only)"
    run gsutil iam ch \
      "user:$GRANTEE:roles/storage.objectCreator" \
      "user:$GRANTEE:roles/storage.objectViewer" \
      "gs://$BUCKET"
    log ""
    log "Send them: https://console.cloud.google.com/storage/browser/$BUCKET"
    log "They can add files and see what they added — nothing else in the project."
    ;;

  *)
    die "unknown action '$ACTION' (expected: create | grant <email>)"
    ;;
esac

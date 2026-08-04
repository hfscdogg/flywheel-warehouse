#!/usr/bin/env bash
# 04-agent-key.sh <client-slug> mint|rotate|revoke — SA key escape hatch.
#
# PREFER NOT TO RUN THIS. The design is impersonation-first: agents mint
# short-lived tokens for hermes-reader (see docs/trust.md), so nothing
# long-lived exists to leak or rotate. Mint a JSON key ONLY if the agent
# runtime genuinely cannot impersonate.
#
# Keys land in $KEY_DIR (outside the repo; gitignored defensively anyway).
#
# Org-policy note: iam.disableServiceAccountKeyCreation is enforced by
# default on newer GCP organizations. If 'mint' fails with a 403, that's the
# policy working as intended — re-check whether impersonation can work before
# exempting the project (Console: IAM & Admin → Organization Policies, or
# 'gcloud org-policies' with org-level permissions).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 2 ] || { usage_and_exit "$0 (actions: mint | rotate | revoke)"; }
load_client "$1"
ACTION="$2"
require_cmd gcloud

KEY_FILE="$KEY_DIR/${SA_HERMES_READER}.json"

list_user_keys() {
  gcloud iam service-accounts keys list --iam-account "$SA_HERMES_READER_EMAIL" \
    --project "$GCP_PROJECT_ID" --managed-by=user --format='value(name.basename())'
}

delete_keys_except() {
  local keep="${1:-}" key
  if is_dry_run; then
    log "[dry-run] delete all user-managed keys on $SA_HERMES_READER_EMAIL${keep:+ except $keep}"
    return 0
  fi
  for key in $(list_user_keys); do
    [ "$key" = "$keep" ] && continue
    run gcloud iam service-accounts keys delete "$key" \
      --iam-account "$SA_HERMES_READER_EMAIL" --project "$GCP_PROJECT_ID" --quiet
  done
}

mint_key_to() {
  local dest="$1"
  run mkdir -p "$KEY_DIR"
  if ! run gcloud iam service-accounts keys create "$dest" \
      --iam-account "$SA_HERMES_READER_EMAIL" --project "$GCP_PROJECT_ID"; then
    die "key creation failed. If the error is a 403/FAILED_PRECONDITION, the
org policy iam.disableServiceAccountKeyCreation is likely enforced (default on
newer orgs). Prefer impersonation (no key needed); see the header of this
script for the exemption path if a key is truly required."
  fi
  run chmod 600 "$dest"
}

case "$ACTION" in
  mint)
    [ -f "$KEY_FILE" ] && die "key already exists at $KEY_FILE — use 'rotate' instead"
    info "Minting key for $SA_HERMES_READER_EMAIL"
    mint_key_to "$KEY_FILE"
    info "Key written to $KEY_FILE (outside the repo — keep it that way)."
    ;;
  rotate)
    info "Rotating key for $SA_HERMES_READER_EMAIL (zero-downtime: mint new, then delete old)"
    mint_key_to "$KEY_FILE.new"
    NEW_KEY_ID=""
    if ! is_dry_run; then
      NEW_KEY_ID="$(grep -o '"private_key_id": *"[^"]*"' "$KEY_FILE.new" | cut -d'"' -f4)"
      [ -n "$NEW_KEY_ID" ] || die "could not read private_key_id from new key file"
    fi
    delete_keys_except "$NEW_KEY_ID"
    run mv "$KEY_FILE.new" "$KEY_FILE"
    info "Rotated. New key at $KEY_FILE; all older user-managed keys deleted."
    ;;
  revoke)
    info "Revoking all user-managed keys for $SA_HERMES_READER_EMAIL"
    delete_keys_except ""
    if [ -f "$KEY_FILE" ]; then
      run rm -f "$KEY_FILE"
    fi
    info "All keys revoked and local file removed."
    ;;
  *)
    die "unknown action '$ACTION' (expected: mint | rotate | revoke)"
    ;;
esac

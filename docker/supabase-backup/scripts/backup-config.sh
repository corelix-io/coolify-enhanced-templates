#!/usr/bin/env bash
#
# backup-config.sh — DB config + crypto keys + secrets manifest (Tier 1).
#
# THE MOST-FORGOTTEN SURFACE. Supabase encrypts columns (Vault / pgsodium) with
# a root key stored in the db-config volume (/etc/postgresql-custom, mounted here
# read-only at $DBCONFIG_DIR). Lose it and encrypted data is unrecoverable.
#
# Also writes a redacted secrets manifest: the NAMES of secrets an operator must
# restore from Coolify env (JWT_SECRET, ANON_KEY, SERVICE_ROLE_KEY, ...). Values
# are never read or written.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="config"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_backup_target

[[ "$CONFIG_ENABLED" == "true" ]] || { log "config backup disabled"; exit 0; }

STAMP="$(ts)"
DEST="config/${STAMP}"
EXT="$(enc_ext)"
START_EPOCH=$(date -u +%s)
trap 'mark_failure config "config backup failed (see logs)"' ERR

log "=== config backup START -> ${DEST} ==="
if [[ -d "$DBCONFIG_DIR" ]]; then
    file_count=$(find "$DBCONFIG_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    log "[db-config] archiving ${file_count} file(s) from ${DBCONFIG_DIR} (pgsodium key + custom conf)"
    tar -C "$DBCONFIG_DIR" -cf - . | gzip -6 | encrypt_stream \
        | put_stream_logged "${DEST}/db-config.tar.gz${EXT}"
else
    warn "[db-config] ${DBCONFIG_DIR} not mounted — pgsodium key NOT captured. Mount supabase-db-config:${DBCONFIG_DIR}:ro to capture it (encrypted columns are unrecoverable without this key)."
fi

# Redacted secrets manifest — names only, no values.
secrets_manifest=$(cat <<'JSON'
{
  "type": "secrets-manifest",
  "note": "Restore these values from your Coolify environment. They are NOT stored in any backup.",
  "required": [
    "JWT_SECRET",
    "ANON_KEY",
    "SERVICE_ROLE_KEY",
    "SECRET_KEY_BASE",
    "SERVICE_PASSWORD_POSTGRES",
    "SERVICE_USER_MINIO",
    "SERVICE_PASSWORD_MINIO",
    "DASHBOARD_USERNAME",
    "DASHBOARD_PASSWORD"
  ]
}
JSON
)
log "[secrets] writing redacted secrets manifest (names only, no values)"
printf '%s' "$secrets_manifest" | put_stream_logged "${DEST}/secrets.manifest.json"

manifest=$(printf '{"type":"config","timestamp":"%s","source_image":"%s","dbconfig_captured":%s,"encryption":"%s"}' \
    "$STAMP" "$SOURCE_IMAGE_TAG" "$([[ -d "$DBCONFIG_DIR" ]] && echo true || echo false)" "$BACKUP_ENCRYPTION")
printf '%s' "$manifest" | put_stream_logged "${DEST}/manifest.json"

trap - ERR
mark_success config
log "=== config backup COMPLETE -> ${DEST} in $(( $(date -u +%s) - START_EPOCH ))s ==="
update_runbook

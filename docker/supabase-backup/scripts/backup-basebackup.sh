#!/usr/bin/env bash
#
# backup-basebackup.sh — physical base backup (Tier 2 / PITR).
#
# pg_basebackup over the replication protocol (no data-dir mount needed).
# Streams a compressed tar to encrypted S3 as basebackups/<ts>/base.tar.gz[.enc]
# plus a manifest recording the start WAL/LSN so prune.sh can retain WAL safely.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="basebackup"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_backup_target

[[ "$PITR_ENABLED" == "true" ]] || { log "PITR disabled — skipping base backup"; exit 0; }

STAMP="$(ts)"
DEST="basebackups/${STAMP}"
EXT="$(enc_ext)"
START_EPOCH=$(date -u +%s)
trap 'mark_failure basebackup "pg_basebackup failed (see logs)"' ERR

if ! wait_for_db 12 5; then die "database not reachable — aborting base backup"; fi

# Record the current WAL insert LSN so prune knows the floor for WAL retention.
start_lsn=$(psql_scalar "SELECT pg_current_wal_lsn()" || echo "unknown")
pg_version=$(psql_scalar "SHOW server_version" || echo "unknown")

log "=== base backup START -> ${DEST} (start_lsn=${start_lsn}, pg=${pg_version}) ==="

# -Ft -X none: tar format, do not include WAL in the base (WAL comes from the
# continuous stream). -z: gzip. -D - : stream the single tar to stdout.
# --checkpoint=fast so we don't wait for the next scheduled checkpoint.
log "[basebackup] pg_basebackup -Ft -z (checkpoint=fast) — this can take a while for large clusters"
pg_basebackup -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
    -D - -Ft -z -X none --checkpoint=fast --no-password \
    | encrypt_stream | put_stream_logged "${DEST}/base.tar.gz${EXT}"

manifest=$(printf '{"type":"basebackup","timestamp":"%s","source_image":"%s","pg_version":"%s","start_lsn":"%s","encryption":"%s","slot":"%s"}' \
    "$STAMP" "$SOURCE_IMAGE_TAG" "$pg_version" "$start_lsn" "$BACKUP_ENCRYPTION" "$REPLICATION_SLOT")
printf '%s' "$manifest" | put_stream_logged "${DEST}/manifest.json"

trap - ERR
mark_success basebackup
log "=== base backup COMPLETE -> ${DEST} in $(( $(date -u +%s) - START_EPOCH ))s ==="
update_runbook

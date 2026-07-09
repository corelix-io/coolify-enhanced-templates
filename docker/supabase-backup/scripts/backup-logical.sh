#!/usr/bin/env bash
#
# backup-logical.sh — portable logical backup (Tier 1).
#
# Produces, per run (timestamped under logical/<ts>/):
#   roles.sql[.enc]   — pg_dumpall --roles-only (restore roles FIRST to defuse
#                       the `supabase_admin` ownership gotcha)
#   <db>.dump[.enc]   — pg_dump -Fc --no-owner --no-privileges per database
#   manifest.json     — source image tag, PG version, db list, encryption
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="logical"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_backup_target

STAMP="$(ts)"
DEST="logical/${STAMP}"
EXT="$(enc_ext)"
START_EPOCH=$(date -u +%s)
trap 'mark_failure logical "logical dump failed (see logs)"' ERR

log "=== logical backup START -> ${DEST} ==="
if ! wait_for_db 12 5; then die "database not reachable — aborting logical backup"; fi
pg_version=$(psql_scalar "SHOW server_version" || echo "unknown")
log "server_version=${pg_version} databases='${BACKUP_DATABASES}' encryption=${BACKUP_ENCRYPTION}"

# 1) Roles (cluster-wide). --no-role-passwords keeps the dump portable/safe;
#    passwords are re-set out of band or preserved via a physical restore.
log "[roles] pg_dumpall --roles-only"
pg_dumpall -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" --roles-only --no-role-passwords \
    | encrypt_stream | put_stream_logged "${DEST}/roles.sql${EXT}"

# 2) Per-database custom-format dumps.
normalized="${BACKUP_DATABASES//,/ }"
for db in $normalized; do
    log "[dump] database '${db}' (pg_dump -Fc)"
    # -Fc = custom (compressed, selective restore). --no-owner/--no-privileges
    # so a clean-cluster restore does not fail on missing supabase_* roles;
    # ownership is reasserted at restore time (--role / roles.sql).
    pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$db" \
        -Fc --no-owner --no-privileges --quote-all-identifiers \
        | encrypt_stream | put_stream_logged "${DEST}/${db}.dump${EXT}"
done

# 3) Manifest.
manifest=$(printf '{"type":"logical","timestamp":"%s","source_image":"%s","pg_version":"%s","databases":"%s","encryption":"%s"}' \
    "$STAMP" "$SOURCE_IMAGE_TAG" "$pg_version" "$normalized" "$BACKUP_ENCRYPTION")
printf '%s' "$manifest" | put_stream_logged "${DEST}/manifest.json"

trap - ERR
mark_success logical
log "=== logical backup COMPLETE -> ${DEST} in $(( $(date -u +%s) - START_EPOCH ))s ==="

# Refresh the restore runbook so the backup folder always documents how to
# recover the newest snapshot set.
update_runbook

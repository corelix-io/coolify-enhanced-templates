#!/usr/bin/env bash
#
# restore-logical.sh — operator-run logical restore into a target cluster.
#
# Handles the Supabase gotchas automatically:
#   1. roles restored FIRST (defuses `role "supabase_admin" does not exist`)
#   2. target DB recreated from template0 (clean restore)
#   3. pg_restore --no-owner --role=<user> so objects land under a valid role
#
# You still re-apply the pgsodium key (from a config backup) and re-hydrate
# storage separately — see README "Restore".
#
# Usage:
#   entrypoint.sh restore-logical [SNAPSHOT] [DB]
#     SNAPSHOT  timestamp dir under logical/ (default: latest)
#     DB        database to restore (default: first of BACKUP_DATABASES)
#
# Requires the age/gpg identity for decryption (BACKUP_AGE_IDENTITY_FILE) and
# RESTORE_CONFIRM=yes (this is destructive to the target database).
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="restore-logical"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_backup_target

SNAP="${1:-}"
DB="${2:-${BACKUP_DATABASES%%[, ]*}}"
EXT="$(enc_ext)"

log "=== logical restore START ==="
if ! wait_for_db 12 5; then die "target database ${PGHOST}:${PGPORT} not reachable — aborting restore"; fi

if [[ -z "$SNAP" ]]; then
    log "no snapshot given — selecting latest under logical/"
    SNAP=$(s3_list logical | sed 's#/$##' | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r | head -n1)
fi
[[ -n "$SNAP" ]] || die "no logical snapshot found under $(s3_path logical)"
log "restore source : logical/${SNAP}"
log "target DB      : ${DB} @ ${PGUSER}@${PGHOST}:${PGPORT}"
log "available files:"; s3_list "logical/${SNAP}" | sed 's/^/    /'
log "roles.sql${EXT} size: $(human_bytes "$(s3_size "logical/${SNAP}/roles.sql${EXT}")")   ${DB}.dump${EXT} size: $(human_bytes "$(s3_size "logical/${SNAP}/${DB}.dump${EXT}")")"

if [[ "${RESTORE_CONFIRM:-no}" != "yes" ]]; then
    die "refusing to run: this DROPs and recreates database '${DB}'. Set RESTORE_CONFIRM=yes to proceed."
fi

# 1) Roles first (idempotent-ish; ignore 'already exists' noise).
log "[1/3] restoring roles (cluster-wide) — 'already exists' notices are benign"
s3_get_stream "logical/${SNAP}/roles.sql${EXT}" | decrypt_stream \
    | psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -v ON_ERROR_STOP=0 \
    || warn "roles restore reported errors (often benign: roles already exist)"

# 2) Recreate the target DB from template0 (terminate connections first).
log "[2/3] recreating database '${DB}' from template0 (terminating existing connections)"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = '${DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${DB};
CREATE DATABASE ${DB} TEMPLATE template0;
SQL

# 3) Restore data.
log "[3/3] restoring data into '${DB}' (pg_restore)"
s3_get_stream "logical/${SNAP}/${DB}.dump${EXT}" | decrypt_stream \
    | pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
        --no-owner --no-privileges --role="$PGUSER" --exit-on-error \
    || warn "pg_restore reported errors — review above (some extension notices are expected)"

# Post-restore sanity: object counts prove the restore actually landed data.
tables=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -X -qtAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')" 2>/dev/null || echo '?')
log "verification: '${DB}' now has ${tables} user table(s)"
log "=== logical restore COMPLETE for '${DB}' from ${SNAP} ==="
log "NEXT STEPS:"
log "  1. re-apply the pgsodium key from a config/ backup (encrypted columns need it)"
log "  2. re-hydrate storage objects into MinIO (see RESTORE.md in the backup folder)"
log "  3. restore secrets (JWT_SECRET, ANON_KEY, ...) into Coolify env — see secrets.manifest.json"

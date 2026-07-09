#!/usr/bin/env bash
#
# restore-pitr.sh — operator-run point-in-time recovery preparation.
#
# Physical restore is intentionally NOT fully automated against a live stack
# (it recreates the data directory of a stopped Postgres). This script does the
# safe, scriptable parts and prints the exact manual steps:
#
#   1. assert the target image major matches the base backup manifest
#   2. fetch + decrypt the chosen base backup into $RESTORE_DATADIR
#   3. write recovery config (recovery.signal, recovery_target_time,
#      restore_command that fetches WAL from S3 via this image)
#   4. print the wal-fetch helper and start/promote instructions
#
# Usage:
#   entrypoint.sh restore-pitr --target-time "2026-07-04 03:14:00+00" \
#       [--base SNAPSHOT] [--datadir /var/lib/postgresql/data]
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="restore-pitr"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_backup_target

TARGET_TIME=""; BASE=""; RESTORE_DATADIR="${RESTORE_DATADIR:-/var/lib/postgresql/data}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-time) TARGET_TIME="$2"; shift 2 ;;
        --base) BASE="$2"; shift 2 ;;
        --datadir) RESTORE_DATADIR="$2"; shift 2 ;;
        --fetch-wal) shift; exec "${SCRIPT_DIR}/wal-fetch.sh" "$@" ;;  # internal
        *) die "unknown arg '$1'" ;;
    esac
done
EXT="$(enc_ext)"

log "=== PITR restore preparation START ==="
[[ -n "$TARGET_TIME" ]] || die "--target-time 'YYYY-MM-DD HH:MM:SS+00' is required"
if [[ -z "$BASE" ]]; then
    log "no --base given — selecting latest under basebackups/"
    BASE=$(s3_list basebackups | sed 's#/$##' | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r | head -n1)
fi
[[ -n "$BASE" ]] || die "no base backup found under $(s3_path basebackups)"
wal_count=$(s3_list wal | grep -c . || echo 0)
log "target time    : ${TARGET_TIME}"
log "base backup    : basebackups/${BASE} ($(human_bytes "$(s3_size "basebackups/${BASE}/base.tar.gz${EXT}")"))"
log "archived WAL   : ${wal_count} segment(s) available under $(s3_path wal)"
log "restore datadir: ${RESTORE_DATADIR}"

# 1) Version guard.
want=$(s3_get_stream "basebackups/${BASE}/manifest.json" 2>/dev/null \
    | sed -n 's/.*"pg_version":"\([0-9]*\)\..*/\1/p' || true)
have=$(pg_config --version 2>/dev/null | sed -n 's/.*PostgreSQL \([0-9]*\)\..*/\1/p' || echo "?")
log "base ${BASE}: pg major ${want:-?}; restore tools major ${have}"
[[ -z "$want" || "$want" == "$have" ]] || warn "PG major mismatch (base=${want} tools=${have}) — restore MUST use supabase/postgres:${want}.x"

if [[ "${RESTORE_CONFIRM:-no}" != "yes" ]]; then
    cat <<EOF
Refusing to write into ${RESTORE_DATADIR} without RESTORE_CONFIRM=yes.
This procedure replaces a Postgres data directory and must run against a STOPPED db.
Re-run with RESTORE_CONFIRM=yes once the target Postgres is stopped and the datadir is empty.
EOF
    exit 1
fi

# 2) Fetch + extract the base backup.
log "extracting base ${BASE} into ${RESTORE_DATADIR}"
mkdir -p "$RESTORE_DATADIR"
[[ -z "$(ls -A "$RESTORE_DATADIR" 2>/dev/null)" ]] || die "datadir ${RESTORE_DATADIR} is not empty"
s3_get_stream "basebackups/${BASE}/base.tar.gz${EXT}" | decrypt_stream | tar -C "$RESTORE_DATADIR" -xzf -

# 3) Recovery config: replay archived WAL from S3 up to the target time.
#    restore_command invokes this image's wal-fetch helper for each segment.
cat > "${RESTORE_DATADIR}/postgresql.auto.conf" <<EOF
# --- corelix supabase-backup PITR (generated $(date -u +%Y-%m-%dT%H:%M:%SZ)) ---
restore_command = '/scripts/wal-fetch.sh %f %p'
recovery_target_time = '${TARGET_TIME}'
recovery_target_action = 'promote'
EOF
touch "${RESTORE_DATADIR}/recovery.signal"
log "wrote recovery config (target_time=${TARGET_TIME})"

cat <<EOF

Base restored and recovery configured. To complete PITR:

  1. Ensure supabase/postgres:${want:-<major>}.x owns ${RESTORE_DATADIR}
       chown -R 105:106 ${RESTORE_DATADIR}   # postgres uid/gid in supabase image
  2. Make this image's /scripts + backup env available to Postgres so
     restore_command can fetch WAL (mount the scripts dir or bake env), OR
     pre-stage WAL: run 'entrypoint.sh restore-pitr --fetch-wal <file> <dest>' per segment.
  3. Start Postgres. It replays WAL to ${TARGET_TIME} and promotes.
  4. Re-apply the pgsodium key from a config backup, then bring up the rest of
     the Supabase stack and re-hydrate storage.

EOF
log "PITR preparation complete"

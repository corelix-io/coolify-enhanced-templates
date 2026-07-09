#!/usr/bin/env bash
#
# entrypoint.sh — dispatcher for the Supabase backup sidecar.
#
#   entrypoint.sh run            (default) long-running: WAL stream + cron + status page
#   entrypoint.sh setup-pitr     one-shot: create replication slot + pg_hba line
#   entrypoint.sh backup-logical | backup-basebackup | backup-storage |
#                 backup-config | prune | verify | ship-wal
#   entrypoint.sh restore-logical [args...] | restore-pitr [args...]
#   entrypoint.sh preflight      test S3 connect+write+read+delete (and MinIO)
#   entrypoint.sh diagnose       DB reachability/auth + slot + S3/MinIO checks
#   entrypoint.sh gen-runbook    (re)generate RESTORE.md in the backup folder
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="entrypoint"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CMD="${1:-run}"
shift || true

render_crontab() {
    # dcron reads /etc/crontabs/root. Only schedule enabled jobs.
    # NOTE: no SHELL=/PATH= lines — dcron rejects env-var lines ("failed parsing
    # crontab"). The scripts are bash (shebang) and source lib.sh, which sets PATH
    # and loads the env snapshot, so scheduled jobs get the full config.
    local ct=/etc/crontabs/root
    : > "$ct"
    {
        echo "${SCHED_LOGICAL:-0 */6 * * *} /scripts/backup-logical.sh >>/proc/1/fd/1 2>&1"
        [[ "$STORAGE_ENABLED" == "true" ]] && \
            echo "${SCHED_STORAGE:-0 4 * * *} /scripts/backup-storage.sh >>/proc/1/fd/1 2>&1"
        [[ "$CONFIG_ENABLED" == "true" ]] && \
            echo "${SCHED_CONFIG:-0 4 * * *} /scripts/backup-config.sh >>/proc/1/fd/1 2>&1"
        if [[ "$PITR_ENABLED" == "true" ]]; then
            echo "${SCHED_BASEBACKUP:-0 3 * * 0} /scripts/backup-basebackup.sh >>/proc/1/fd/1 2>&1"
            echo "${SCHED_WAL_SHIP:-* * * * *} /scripts/ship-wal.sh >>/proc/1/fd/1 2>&1"
        fi
        echo "${SCHED_PRUNE:-30 5 * * *} /scripts/prune.sh >>/proc/1/fd/1 2>&1"
        [[ "${VERIFY_ENABLED:-true}" == "true" ]] && \
            echo "${SCHED_VERIFY:-0 5 * * 1} /scripts/verify.sh >>/proc/1/fd/1 2>&1"
    } >> "$ct"
    log "crontab installed:"; sed 's/^/    /' "$ct"
}

start_status_server() {
    mkdir -p "$STATUS_DIR"; render_status
    # darkhttpd is tiny and serves the static status dir. Non-fatal if it dies.
    darkhttpd "$STATUS_DIR" --port "${STATUS_PORT:-8080}" --addr 0.0.0.0 >/dev/null 2>&1 &
    log "status page on :${STATUS_PORT:-8080}"
}

start_wal_stream() {
    [[ "$PITR_ENABLED" == "true" ]] || { log "PITR disabled — WAL streaming off"; return 0; }
    "${SCRIPT_DIR}/stream-wal.sh" &
    WAL_PID=$!
    log "pg_receivewal streaming started (pid ${WAL_PID})"
}

case "$CMD" in
    setup-pitr)       exec "${SCRIPT_DIR}/setup-pitr.sh" "$@" ;;
    backup-logical)   exec "${SCRIPT_DIR}/backup-logical.sh" "$@" ;;
    backup-basebackup) exec "${SCRIPT_DIR}/backup-basebackup.sh" "$@" ;;
    backup-storage)   exec "${SCRIPT_DIR}/backup-storage.sh" "$@" ;;
    backup-config)    exec "${SCRIPT_DIR}/backup-config.sh" "$@" ;;
    ship-wal)         exec "${SCRIPT_DIR}/ship-wal.sh" "$@" ;;
    prune)            exec "${SCRIPT_DIR}/prune.sh" "$@" ;;
    verify)           exec "${SCRIPT_DIR}/verify.sh" "$@" ;;
    restore-logical)  exec "${SCRIPT_DIR}/restore-logical.sh" "$@" ;;
    restore-pitr)     exec "${SCRIPT_DIR}/restore-pitr.sh" "$@" ;;
    restore-runbook|gen-runbook) exec "${SCRIPT_DIR}/restore-runbook.sh" "$@" ;;
    preflight)        check_encryption_config; s3_preflight; minio_preflight; exit 0 ;;
    diagnose)         diagnose_db; check_encryption_config; s3_preflight; minio_preflight; exit 0 ;;
    healthcheck)      exec "${SCRIPT_DIR}/healthcheck.sh" "$@" ;;
    run)
        log "starting supabase-backup sidecar (prefix=${BACKUP_PREFIX}, pitr=${PITR_ENABLED})"
        log_config_banner

        # 1) Wait (verbosely) for the DB — reports DNS/TCP/ready/auth per attempt.
        if ! wait_for_db 60 5; then
            die "database ${PGHOST}:${PGPORT} never became reachable after 5 minutes — see attempts above. The scheduler will NOT start."
        fi

        # 2) Validate encryption config (fail fast if age/gpg recipient missing),
        #    then prove the backup target works before we ever run a job. Failures
        #    here are fatal at startup so they're obvious, not buried 6h later.
        check_encryption_config
        s3_preflight
        minio_preflight

        # 3) Generate an initial restore runbook so the backup folder always has
        #    RESTORE.md (even before the first scheduled backup runs).
        update_runbook

        start_status_server
        start_wal_stream
        render_crontab

        # Snapshot the environment so cron-spawned jobs (which dcron starts with
        # only a minimal env) see PGPASSWORD, BACKUP_S3_*, the age recipient, etc.
        # lib.sh sources this file. Written 0600 (contains secrets) in /tmp, not
        # in the mounted staging volume.
        ( umask 077; export -p > "${CORELIX_ENV_FILE:-/tmp/corelix-backup.env}" )
        log "environment snapshot written for scheduled jobs -> ${CORELIX_ENV_FILE:-/tmp/corelix-backup.env}"

        log "startup complete — handing off to crond (schedules above)"
        exec crond -f -l 8
        ;;
    *)
        die "unknown command '$CMD'"
        ;;
esac

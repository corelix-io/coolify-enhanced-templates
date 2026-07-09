#!/usr/bin/env bash
#
# stream-wal.sh — continuous WAL capture (Tier 2 / PITR).
#
# pg_receivewal streams completed WAL segments from the physical replication
# slot into $WAL_DIR. A separate ship-wal.sh (cron, every minute) encrypts and
# uploads finished (non-.partial) segments to S3, then removes local copies.
#
# Runs in the foreground; entrypoint.sh backgrounds it and restarts on exit.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="stream-wal"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

[[ "$PITR_ENABLED" == "true" ]] || { log "PITR disabled"; exit 0; }
mkdir -p "$WAL_DIR"

# --slot ties retention to the slot created by setup-pitr.sh; --if-not-exists is
# a safety net. --no-loop is omitted so pg_receivewal reconnects on transient
# drops; we wrap in our own restart loop for hard failures.
while true; do
    log "connecting pg_receivewal (slot=${REPLICATION_SLOT}) -> ${WAL_DIR}"
    if pg_receivewal -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
        --slot="$REPLICATION_SLOT" --if-not-exists \
        --directory="$WAL_DIR" --no-password; then
        log "pg_receivewal exited cleanly"
    else
        warn "pg_receivewal exited with error — retrying in 15s"
    fi
    sleep 15
done

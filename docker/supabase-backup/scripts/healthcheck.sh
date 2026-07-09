#!/usr/bin/env bash
#
# healthcheck.sh — container healthcheck.
#
# Unhealthy when:
#   * the DB is unreachable, OR
#   * PITR is on but the replication slot is missing / lagging beyond
#     WAL_LAG_MAX_BYTES (an unconsumed/stalled slot silently retains WAL and can
#     fill the server disk), OR
#   * the newest successful logical backup is older than BACKUP_STALE_SECONDS.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="health"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${WAL_LAG_MAX_BYTES:=10737418240}"      # 10 GiB
: "${BACKUP_STALE_SECONDS:=129600}"        # 36h (> default 6h logical cadence)

# DB reachable?
pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" >/dev/null 2>&1 || { echo "db unreachable"; exit 1; }

# Replication slot health.
if [[ "$PITR_ENABLED" == "true" ]]; then
    lag=$(psql_scalar "
        SELECT COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0)::bigint
        FROM pg_replication_slots WHERE slot_name = '${REPLICATION_SLOT}'" 2>/dev/null || echo "")
    [[ -n "$lag" ]] || { echo "replication slot ${REPLICATION_SLOT} missing"; exit 1; }
    if [[ "$lag" -gt "$WAL_LAG_MAX_BYTES" ]]; then
        echo "replication slot lag ${lag} bytes > ${WAL_LAG_MAX_BYTES}"; exit 1
    fi
fi

# Freshness of the last logical success.
marker="${STATUS_DIR}/last_success_logical"
if [[ -f "$marker" ]]; then
    age=$(( $(date -u +%s) - $(cat "$marker") ))
    if [[ "$age" -gt "$BACKUP_STALE_SECONDS" ]]; then
        echo "last logical backup ${age}s ago (> ${BACKUP_STALE_SECONDS})"; exit 1
    fi
fi
echo "ok"

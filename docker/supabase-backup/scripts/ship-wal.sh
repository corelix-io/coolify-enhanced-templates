#!/usr/bin/env bash
#
# ship-wal.sh — encrypt + upload completed WAL segments (Tier 2 / PITR).
#
# Invoked frequently by cron (default every minute). pg_receivewal writes the
# in-progress segment as *.partial; only fully written segments are shipped.
# After a successful upload the local copy is removed so $WAL_DIR stays bounded.
#
# A per-run flock avoids overlapping shippers.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="ship-wal"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_backup_target

[[ "$PITR_ENABLED" == "true" ]] || exit 0

# Dependency-free mutex: mkdir is atomic. Prevents overlapping shippers when a
# run takes longer than the (1-minute) cron interval.
LOCKDIR="${STAGING_DIR}/.ship-wal.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    log "another shipper is running — skipping"; exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

mkdir -p "$WAL_DIR"
EXT="$(enc_ext)"
shipped=0
failed=0

shopt -s nullglob
for seg in "$WAL_DIR"/*; do
    base="$(basename "$seg")"
    # Skip in-progress segments and our own lock/temp files.
    case "$base" in
        *.partial|.*) continue ;;
    esac
    [[ -f "$seg" ]] || continue

    seg_bytes=$(stat -c %s "$seg" 2>/dev/null || echo 0)
    if encrypt_stream < "$seg" | s3_put_stream "wal/${base}${EXT}"; then
        rm -f "$seg"
        shipped=$((shipped + 1))
        log "shipped WAL ${base} ($(human_bytes "$seg_bytes")) -> $(s3_path "wal/${base}${EXT}")"
    else
        warn "failed to ship WAL segment ${base}"
        failed=$((failed + 1))
    fi
done

if [[ $failed -gt 0 ]]; then
    mark_failure wal "failed to ship ${failed} WAL segment(s)"
    exit 1
fi
[[ $shipped -gt 0 ]] && log "WAL ship cycle: ${shipped} segment(s) uploaded" || debug "WAL ship cycle: no completed segments to ship"
mark_success wal

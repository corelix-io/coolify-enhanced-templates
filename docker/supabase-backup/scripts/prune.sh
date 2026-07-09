#!/usr/bin/env bash
#
# prune.sh — retention.
#
#   logical/, storage/, config/  -> GFS (keep last N daily, weekly, monthly)
#   basebackups/                 -> keep the RETAIN_BASEBACKUPS most recent
#   wal/                         -> delete segments older than the WAL file that
#                                   contains the oldest RETAINED base backup's
#                                   start LSN (never orphan a kept base)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="prune"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_backup_target

trap 'mark_failure prune "prune failed (see logs)"' ERR

# List timestamp dir names (e.g. 20260704T031500Z) under a category prefix.
list_snapshots() { s3_list "$1" | sed 's#/$##' | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r; }

# 20260704T031500Z -> epoch (via reformat to ISO). Prints epoch seconds.
stamp_epoch() {
    local s="$1"
    local iso="${s:0:4}-${s:4:2}-${s:6:2} ${s:9:2}:${s:11:2}:${s:13:2}Z"
    date -u -d "$iso" +%s
}

# GFS keep-set: newest RETAIN_DAILY distinct days, newest RETAIN_WEEKLY distinct
# ISO weeks, newest RETAIN_MONTHLY distinct months. Reads stamps (desc) on stdin.
gfs_prune() {
    local category="$1"
    local -A keep=() seen_day=() seen_week=() seen_month=()
    local dcount=0 wcount=0 mcount=0
    local stamps; stamps=$(list_snapshots "$category")
    [[ -n "$stamps" ]] || { log "${category}: nothing to prune"; return 0; }

    local s epoch day week month
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        epoch=$(stamp_epoch "$s")
        day=$(date -u -d "@$epoch" +%Y%m%d)
        week=$(date -u -d "@$epoch" +%G%V)
        month=$(date -u -d "@$epoch" +%Y%m)
        if [[ -z "${seen_day[$day]:-}" && $dcount -lt $RETAIN_DAILY ]]; then
            keep[$s]=1; seen_day[$day]=1; dcount=$((dcount+1))
        fi
        if [[ -z "${seen_week[$week]:-}" && $wcount -lt $RETAIN_WEEKLY ]]; then
            keep[$s]=1; seen_week[$week]=1; wcount=$((wcount+1))
        fi
        if [[ -z "${seen_month[$month]:-}" && $mcount -lt $RETAIN_MONTHLY ]]; then
            keep[$s]=1; seen_month[$month]=1; mcount=$((mcount+1))
        fi
    done <<< "$stamps"

    local deleted=0
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        if [[ -z "${keep[$s]:-}" ]]; then
            log "${category}: pruning ${s}"
            s3_delete "${category}/${s}"
            deleted=$((deleted+1))
        fi
    done <<< "$stamps"
    log "${category}: kept ${#keep[@]}, pruned ${deleted}"
}

gfs_prune logical
gfs_prune storage
gfs_prune config

# ---- Base backups (count-based) + WAL floor ------------------------------- #
if [[ "$PITR_ENABLED" == "true" ]]; then
    bases=$(list_snapshots basebackups)
    if [[ -n "$bases" ]]; then
        kept_bases=$(echo "$bases" | head -n "$RETAIN_BASEBACKUPS")
        oldest_kept=$(echo "$kept_bases" | tail -n1)
        # Delete bases older than the oldest kept.
        echo "$bases" | tail -n +"$((RETAIN_BASEBACKUPS + 1))" | while IFS= read -r s; do
            [[ -n "$s" ]] || continue
            log "basebackups: pruning ${s}"
            s3_delete "basebackups/${s}"
        done

        # WAL floor: the WAL file containing the oldest kept base's start LSN.
        start_lsn=$(s3_get_stream "basebackups/${oldest_kept}/manifest.json" 2>/dev/null \
            | sed -n 's/.*"start_lsn":"\([^"]*\)".*/\1/p' || true)
        if [[ -n "$start_lsn" && "$start_lsn" != "unknown" ]]; then
            floor=$(psql_scalar "SELECT pg_walfile_name('${start_lsn}')" 2>/dev/null || true)
            if [[ -n "$floor" ]]; then
                log "wal: retaining segments >= ${floor} (base ${oldest_kept})"
                deleted=0
                for f in $(s3_list wal | sed 's#/$##'); do
                    seg="${f%%.*}"     # strip .age/.gpg extension -> 24-hex WAL name
                    # WAL names sort lexically in creation order.
                    if [[ "$seg" < "$floor" ]]; then
                        s3_delete "wal/${f}"; deleted=$((deleted+1))
                    fi
                done
                log "wal: pruned ${deleted} segment(s) below floor"
            else
                warn "wal: could not resolve floor WAL name from LSN ${start_lsn} — skipping WAL prune"
            fi
        else
            warn "wal: oldest kept base has no start_lsn — skipping WAL prune (safe)"
        fi
    fi
fi

trap - ERR
mark_success prune
log "prune complete"

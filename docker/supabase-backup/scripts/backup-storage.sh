#!/usr/bin/env bash
#
# backup-storage.sh — Supabase Storage objects (Tier 1).
#
# The database only stores object *metadata*; the bytes live in MinIO. We pull
# the bucket's logical objects over the S3 API with `rclone sync` (NOT a raw
# volume tar — that captures MinIO's internal on-disk/erasure layout and is
# fragile), archive the mirrored objects to a single tar, encrypt, and upload.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="storage"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_backup_target

[[ "$STORAGE_ENABLED" == "true" ]] || { log "storage backup disabled"; exit 0; }
[[ -n "$MINIO_ACCESS_KEY" && -n "$MINIO_SECRET_KEY" ]] \
    || die "MINIO_ACCESS_KEY / MINIO_SECRET_KEY required for storage backup"

STAMP="$(ts)"
DEST="storage/${STAMP}"
EXT="$(enc_ext)"
START_EPOCH=$(date -u +%s)
MIRROR="${STAGING_DIR}/storage-mirror"
trap 'mark_failure storage "storage backup failed (see logs)"; rm -rf "$MIRROR"' ERR

log "=== storage backup START -> ${DEST} ==="
# Confirm the MinIO source before we try to pull from it.
if ! rclone lsf "minio:${STORAGE_BUCKET}" >/dev/null 2>&1; then
    die "MinIO source bucket '${STORAGE_BUCKET}' at ${MINIO_ENDPOINT} not reachable — check MINIO_ENDPOINT / MINIO_ACCESS_KEY / MINIO_SECRET_KEY / STORAGE_BUCKET"
fi
log "[mirror] rclone sync minio:${STORAGE_BUCKET} -> ${MIRROR} (S3 API)"
mkdir -p "$MIRROR"
# Logical object sync via the S3 API. --fast-list keeps large buckets efficient.
rclone sync "minio:${STORAGE_BUCKET}" "$MIRROR" --fast-list --transfers 8 --stats-one-line

object_count=$(find "$MIRROR" -type f | wc -l | tr -d ' ')
mirror_bytes=$(du -sb "$MIRROR" 2>/dev/null | awk 'NR==1{print $1}'); : "${mirror_bytes:=0}"
log "[mirror] ${object_count} object(s), $(human_bytes "$mirror_bytes") — archiving + encrypting"

# Tar the *logical objects* (real files pulled via the API), then encrypt.
tar -C "$MIRROR" -cf - . | gzip -6 | encrypt_stream | put_stream_logged "${DEST}/storage.tar.gz${EXT}"

manifest=$(printf '{"type":"storage","timestamp":"%s","bucket":"%s","object_count":%s,"encryption":"%s"}' \
    "$STAMP" "$STORAGE_BUCKET" "$object_count" "$BACKUP_ENCRYPTION")
printf '%s' "$manifest" | put_stream_logged "${DEST}/manifest.json"

rm -rf "$MIRROR"
trap - ERR
mark_success storage
log "=== storage backup COMPLETE -> ${DEST} (${object_count} objects) in $(( $(date -u +%s) - START_EPOCH ))s ==="
update_runbook

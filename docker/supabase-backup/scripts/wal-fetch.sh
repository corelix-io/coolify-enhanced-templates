#!/usr/bin/env bash
#
# wal-fetch.sh — Postgres restore_command helper.
#
# Called by Postgres during PITR recovery as: wal-fetch.sh %f %p
#   %f = requested WAL filename, %p = destination path (relative to datadir)
#
# Fetches wal/<f>[.enc] from S3, decrypts, and writes it to %p. Exit non-zero
# when the segment is absent so Postgres knows recovery has reached the end of
# the archived stream.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="wal-fetch"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_backup_target

WANT="${1:?WAL filename required}"
DEST="${2:?destination path required}"
EXT="$(enc_ext)"

if rclone lsf "$(s3_path "wal/${WANT}${EXT}")" >/dev/null 2>&1; then
    s3_get_stream "wal/${WANT}${EXT}" | decrypt_stream > "$DEST"
    exit 0
fi
# Not an error to log loudly — end-of-archive is normal.
exit 1

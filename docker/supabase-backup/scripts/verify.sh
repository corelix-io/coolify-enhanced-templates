#!/usr/bin/env bash
#
# verify.sh — backup trust check, in two tiers.
#
# Tier A — STRUCTURAL (default; needs NO private key). Confirms the latest
#   logical set's objects exist in S3, are non-trivially sized, and — for age —
#   begin with a valid age header. Proves the backup is present and well-formed
#   WITHOUT ever decrypting, which matches the offline-key model: the backup box
#   holds only the age *public* key, so it cannot (and must not need to) decrypt.
#
# Tier B — DEEP (only when a decryption key is available, or VERIFY_DECRYPT=true).
#   Decrypts each dump and runs `pg_restore --list` end-to-end (proves decryption
#   + archive TOC integrity). Optional full test-restore into a scratch server
#   (VERIFY_FULL=true, VERIFY_PGHOST=...).
#
# VERIFY_DECRYPT: auto (default) | true | false
#   auto  -> deep if a decryption key is present, else structural-only
#   true  -> force deep; fail if no key is available
#   false -> force structural-only (never touch the key even if present)
#
# To run a DEEP verify on demand without keeping the private key on the backup
# box, invoke `verify` in a one-off container with the identity mounted:
#   docker run --rm -e BACKUP_AGE_IDENTITY_FILE=/keys/age.key \
#     -v /path/age.key:/keys/age.key:ro ... <image> verify
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="verify"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_backup_target

trap 'mark_failure verify "verification failed (see logs)"' ERR

: "${VERIFY_MIN_BYTES:=100}"          # floor below which an object is "too small"

latest=$(s3_list logical | sed 's#/$##' | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r | head -n1)
[[ -n "$latest" ]] || die "no logical backups found to verify"
EXT="$(enc_ext)"
normalized="${BACKUP_DATABASES//,/ }"

# True when this container can actually decrypt backups.
can_decrypt() {
    case "$BACKUP_ENCRYPTION" in
        none) return 0 ;;
        age)  [[ -n "$BACKUP_AGE_IDENTITY_FILE" && -f "$BACKUP_AGE_IDENTITY_FILE" ]] ;;
        gpg)  gpg --list-secret-keys >/dev/null 2>&1 && [[ -n "$(gpg --list-secret-keys 2>/dev/null)" ]] ;;
        *)    return 1 ;;
    esac
}

# Resolve the effective mode.
MODE="${VERIFY_DECRYPT:-auto}"
case "$MODE" in
    auto)  if can_decrypt; then MODE=deep; else MODE=structural; fi ;;
    true)  can_decrypt || die "VERIFY_DECRYPT=true but no decryption key is available — set BACKUP_AGE_IDENTITY_FILE to the age private key (or import a gpg secret key)."
           MODE=deep ;;
    false) MODE=structural ;;
    *)     die "VERIFY_DECRYPT must be auto|true|false (got '${MODE}')" ;;
esac
log "verifying latest logical set: ${latest} (mode=${MODE}, encryption=${BACKUP_ENCRYPTION})"

# ---- Tier A: structural (always runs; cheap; no key) ---------------------- #
# Confirms presence + plausible size, and (for age) a valid header via a 64-byte
# range read — catches missing, truncated, empty, or non-age objects.
check_object() {                        # $1 = relative path ; $2 = expect_age(0/1) ; $3 = min bytes
    local rel="$1" expect_age="${2:-0}" min="${3:-$VERIFY_MIN_BYTES}" size
    size="$(s3_size "$rel" 2>/dev/null || true)"
    if [[ -z "$size" || "$size" -eq 0 ]]; then
        warn "  MISSING/empty: $(s3_path "$rel")"; return 1
    fi
    if [[ "$size" -lt "$min" ]]; then
        warn "  suspiciously small (${size} B < ${min}): ${rel}"; return 1
    fi
    if [[ "$expect_age" == "1" && "$BACKUP_ENCRYPTION" == "age" ]]; then
        # grep -a (text mode) over a byte-range read — no command-substitution of
        # binary (which triggers bash null-byte warnings) and no full download.
        if s3_head_bytes "$rel" 64 | grep -qa 'age-encryption.org'; then
            log "  OK structural: ${rel} ($(human_bytes "$size"), age header present)"
        else
            warn "  no age header — corrupt or not encrypted: ${rel}"; return 1
        fi
    else
        log "  OK structural: ${rel} ($(human_bytes "$size"))"
    fi
    return 0
}

fail=0
check_object "logical/${latest}/manifest.json" 0 2 || fail=1   # plaintext JSON, tiny
check_object "logical/${latest}/roles.sql${EXT}" 1 || fail=1
for db in $normalized; do
    check_object "logical/${latest}/${db}.dump${EXT}" 1 || fail=1
done
[[ $fail -eq 0 ]] || die "structural verification FAILED for ${latest} (see warnings above)"
log "structural check passed for ${latest}"

if [[ "$MODE" != "deep" ]]; then
    trap - ERR
    mark_success verify
    log "verification complete (structural only). For full decrypt+restore checks, run this with the"
    log "private key: -e BACKUP_AGE_IDENTITY_FILE=/keys/age.key -v <key>:/keys/age.key:ro  (or VERIFY_DECRYPT=true)."
    exit 0
fi

# ---- Tier B: deep integrity (decrypt + pg_restore --list) ----------------- #
log "deep verify: decrypting + pg_restore --list on each dump"
for db in $normalized; do
    obj="logical/${latest}/${db}.dump${EXT}"
    log "  checking ${obj}"
    if ! s3_get_stream "$obj" | decrypt_stream | pg_restore --list >/dev/null; then
        die "pg_restore --list failed for ${db} (corrupt archive or wrong key)"
    fi
done
log "deep integrity check passed for ${latest}"

if [[ "${VERIFY_FULL:-false}" == "true" ]]; then
    [[ -n "${VERIFY_PGHOST:-}" ]] || die "VERIFY_FULL=true requires VERIFY_PGHOST (scratch server)"
    scratch="verify_$(date -u +%s)"
    log "full test-restore into ${VERIFY_PGHOST}/${scratch}"
    PGPASSWORD="${VERIFY_PGPASSWORD:-$PGPASSWORD}" \
        psql -h "$VERIFY_PGHOST" -U "${VERIFY_PGUSER:-$PGUSER}" -d postgres \
        -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${scratch} TEMPLATE template0"
    first_db="${normalized%% *}"
    s3_get_stream "logical/${latest}/${first_db}.dump${EXT}" | decrypt_stream \
        | PGPASSWORD="${VERIFY_PGPASSWORD:-$PGPASSWORD}" \
          pg_restore -h "$VERIFY_PGHOST" -U "${VERIFY_PGUSER:-$PGUSER}" -d "$scratch" \
          --no-owner --no-privileges || warn "restore reported non-fatal errors"
    tables=$(PGPASSWORD="${VERIFY_PGPASSWORD:-$PGPASSWORD}" \
        psql -h "$VERIFY_PGHOST" -U "${VERIFY_PGUSER:-$PGUSER}" -d "$scratch" -X -qtAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
    log "scratch restore has ${tables} public table(s)"
    PGPASSWORD="${VERIFY_PGPASSWORD:-$PGPASSWORD}" \
        psql -h "$VERIFY_PGHOST" -U "${VERIFY_PGUSER:-$PGUSER}" -d postgres \
        -c "DROP DATABASE ${scratch}" || warn "could not drop scratch DB ${scratch}"
fi

trap - ERR
mark_success verify
log "verification complete (deep)."

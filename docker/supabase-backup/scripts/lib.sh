#!/usr/bin/env bash
#
# lib.sh — shared helpers for the Corelix self-hosted Supabase backup sidecar.
#
# Sourced by every other script. Provides: env contract + defaults, logging,
# rclone remote configuration (backup S3 + MinIO source), age/gpg encryption
# streams, S3 path helpers, status/state markers, and webhook alerting.
#
# All shell interpolations that reach a subshell/program are quoted; values that
# come from user config are never eval'd.

set -euo pipefail

# Directory this library lives in (used to invoke sibling scripts, e.g. the
# restore-runbook generator) regardless of the caller's CWD.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --------------------------------------------------------------------------- #
# Cron environment bridge                                                      #
# --------------------------------------------------------------------------- #
# dcron (Dillon's cron) gives scheduled jobs only a MINIMAL environment — it
# does NOT pass the container's env, and it rejects SHELL=/PATH= lines in the
# crontab. So the `run` command snapshots the environment at startup to this
# file, and every script sources it here BEFORE the env-contract checks below.
# Without this, scheduled backups would start with PGPASSWORD/BACKUP_S3_*/age
# recipient all unset and die immediately. Interactive runs (no snapshot file)
# simply skip it and use the process env.
: "${CORELIX_ENV_FILE:=/tmp/corelix-backup.env}"
if [[ -f "$CORELIX_ENV_FILE" ]]; then
    # Preserve the per-script LOG_TAG (each script sets it before sourcing lib);
    # the snapshot carries the startup tag and would otherwise clobber it.
    __prev_log_tag="${LOG_TAG:-}"
    set +u +e; set -a
    # shellcheck disable=SC1090
    . "$CORELIX_ENV_FILE" 2>/dev/null || true
    set +a; set -eu
    [[ -n "$__prev_log_tag" ]] && LOG_TAG="$__prev_log_tag"
    unset __prev_log_tag
fi
# Defensive PATH so the Postgres client tools in /usr/local/bin are found even
# if the snapshot is missing (cron's default PATH omits /usr/local/bin).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/scripts"

# --------------------------------------------------------------------------- #
# Environment contract (defaults mirror Coolify's official Supabase template)  #
# --------------------------------------------------------------------------- #

# Source database
: "${PGHOST:=supabase-db}"
: "${PGPORT:=5432}"
: "${PGUSER:=supabase_admin}"
: "${PGPASSWORD:?PGPASSWORD is required (Supabase SERVICE_PASSWORD_POSTGRES)}"
: "${PGDATABASE:=postgres}"
# Databases to logically dump (space/comma separated). Default: the primary DB.
: "${BACKUP_DATABASES:=postgres}"

# PITR (physical) tier
: "${PITR_ENABLED:=true}"
: "${PITR_SETUP:=auto}"                 # auto | manual
: "${REPLICATION_SLOT:=corelix_backup}"
: "${REPLICATION_CIDR:=samenet}"        # pg_hba scope for the replication line

# Storage (MinIO — Supabase's object backend)
: "${STORAGE_ENABLED:=true}"
: "${MINIO_ENDPOINT:=http://supabase-minio:9000}"
: "${MINIO_ACCESS_KEY:=}"
: "${MINIO_SECRET_KEY:=}"
: "${STORAGE_BUCKET:=stub}"
: "${MINIO_REGION:=us-east-1}"

# Config / crypto capture (pgsodium key lives in the db-config volume)
: "${CONFIG_ENABLED:=true}"
: "${DBCONFIG_DIR:=/dbconfig}"

# Backup target (any S3-compatible endpoint). Defaulted empty so setup-pitr /
# healthcheck can source this lib without them; require_backup_target() enforces
# presence in the scripts that actually upload/download.
: "${BACKUP_S3_ENDPOINT:=}"
: "${BACKUP_S3_BUCKET:=}"
: "${BACKUP_S3_ACCESS_KEY:=}"
: "${BACKUP_S3_SECRET_KEY:=}"
: "${BACKUP_S3_REGION:=us-east-1}"
: "${BACKUP_S3_FORCE_PATH_STYLE:=true}"
# Path prefix inside the bucket; keep distinct per Supabase stack.
: "${BACKUP_PREFIX:=supabase}"

# Encryption — age is default; gpg optional. One recipient MUST be set unless
# BACKUP_ENCRYPTION=none (strongly discouraged; only for already-encrypted targets).
: "${BACKUP_ENCRYPTION:=age}"           # age | gpg | none
: "${BACKUP_AGE_RECIPIENT:=}"           # age1... public key (encrypt)
: "${BACKUP_AGE_IDENTITY_FILE:=}"       # age private key file (restore only)
: "${BACKUP_GPG_RECIPIENT:=}"           # gpg key id/email (encrypt)

# Retention (GFS + physical)
: "${RETAIN_DAILY:=7}"
: "${RETAIN_WEEKLY:=4}"
: "${RETAIN_MONTHLY:=6}"
: "${RETAIN_BASEBACKUPS:=4}"            # keep N most-recent base backups; WAL pruned before oldest kept

# Operational
: "${STAGING_DIR:=/staging}"
: "${STATUS_DIR:=${STAGING_DIR}/www}"
: "${WAL_DIR:=${STAGING_DIR}/wal}"
: "${ALERT_WEBHOOK:=}"
: "${SOURCE_IMAGE_TAG:=unknown}"        # recorded in manifests for restore version-matching

# Verbosity. LOG_LEVEL=debug enables debug() lines and bumps rclone to INFO so
# every transfer is logged. Default 'info' is already far more verbose than the
# original silent scripts. RUNBOOK_ENABLED controls RESTORE.md regeneration.
: "${LOG_LEVEL:=info}"                   # info | debug
: "${RUNBOOK_ENABLED:=true}"
if [[ "$LOG_LEVEL" == "debug" ]]; then
    : "${RCLONE_LOG_LEVEL:=INFO}"
else
    : "${RCLONE_LOG_LEVEL:=NOTICE}"
fi
export RCLONE_LOG_LEVEL

export PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE

# --------------------------------------------------------------------------- #
# Logging                                                                      #
# --------------------------------------------------------------------------- #

log()   { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LOG_TAG:-backup}" "$*"; }
warn()  { log "WARN: $*" >&2; }
die()   { log "FATAL: $*" >&2; alert "failed" "$*"; exit 1; }
debug() { [[ "$LOG_LEVEL" == "debug" ]] && log "DEBUG: $*" || true; }

# Redact a secret for display: keep only the last 4 chars, or "(unset)".
redact() { local v="${1:-}"; [[ -n "$v" ]] && printf '****%s' "${v: -4}" || printf '(unset)'; }

# Pretty-print a byte count (integer) as B/KiB/MiB/GiB/TiB.
human_bytes() {
    local b="${1:-0}"
    [[ "$b" =~ ^[0-9]+$ ]] || { printf '%s' "$b"; return; }
    awk -v b="$b" 'BEGIN{split("B KiB MiB GiB TiB",u," ");i=1;
        while(b>=1024 && i<5){b/=1024;i++}
        if(i==1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]}'
}

# --------------------------------------------------------------------------- #
# Timestamps / S3 paths                                                        #
# --------------------------------------------------------------------------- #

ts()          { date -u +%Y%m%dT%H%M%SZ; }
s3_base()     { printf 'backup:%s/%s' "$BACKUP_S3_BUCKET" "$BACKUP_PREFIX"; }
s3_path()     { printf '%s/%s' "$(s3_base)" "$1"; }   # $1 = relative path

# --------------------------------------------------------------------------- #
# rclone remotes (env-configured; no config file written)                      #
# --------------------------------------------------------------------------- #
# "backup" -> the off-host S3 target; "minio" -> the Supabase MinIO source.

require_backup_target() {
    [[ -n "$BACKUP_S3_ENDPOINT" ]] || die "BACKUP_S3_ENDPOINT is required"
    [[ -n "$BACKUP_S3_BUCKET"   ]] || die "BACKUP_S3_BUCKET is required"
    [[ -n "$BACKUP_S3_ACCESS_KEY" ]] || die "BACKUP_S3_ACCESS_KEY is required"
    [[ -n "$BACKUP_S3_SECRET_KEY" ]] || die "BACKUP_S3_SECRET_KEY is required"
}

configure_rclone() {
    export RCLONE_CONFIG_BACKUP_TYPE=s3
    export RCLONE_CONFIG_BACKUP_PROVIDER=Other
    export RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY"
    export RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_KEY"
    export RCLONE_CONFIG_BACKUP_ENDPOINT="$BACKUP_S3_ENDPOINT"
    export RCLONE_CONFIG_BACKUP_REGION="$BACKUP_S3_REGION"
    export RCLONE_CONFIG_BACKUP_FORCE_PATH_STYLE="$BACKUP_S3_FORCE_PATH_STYLE"
    export RCLONE_CONFIG_BACKUP_NO_CHECK_BUCKET=true

    export RCLONE_CONFIG_MINIO_TYPE=s3
    export RCLONE_CONFIG_MINIO_PROVIDER=Minio
    export RCLONE_CONFIG_MINIO_ACCESS_KEY_ID="$MINIO_ACCESS_KEY"
    export RCLONE_CONFIG_MINIO_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY"
    export RCLONE_CONFIG_MINIO_ENDPOINT="$MINIO_ENDPOINT"
    export RCLONE_CONFIG_MINIO_REGION="$MINIO_REGION"
    export RCLONE_CONFIG_MINIO_FORCE_PATH_STYLE=true
}

# Stream stdin to an S3 object at $1 (relative path under the prefix).
s3_put_stream() { rclone rcat --s3-no-check-bucket "$(s3_path "$1")"; }
# Upload a local file $1 to relative object path $2.
s3_put_file()   { rclone copyto --s3-no-check-bucket "$1" "$(s3_path "$2")"; }
# Stream an S3 object at $1 to stdout.
s3_get_stream() { rclone cat "$(s3_path "$1")"; }
# List object leaf-names under relative prefix $1 (newest sorting done by caller).
s3_list()       { rclone lsf "$(s3_path "$1")" 2>/dev/null || true; }
# Delete relative object/dir $1.
s3_delete()     { rclone delete --s3-no-check-bucket "$(s3_path "$1")" 2>/dev/null || true; }
# Size (bytes) of a single S3 object at relative path $1; empty on error.
s3_size()       { rclone size --json "$(s3_path "$1")" 2>/dev/null | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p'; }
# First $2 (default 64) bytes of an S3 object at relative path $1, to stdout.
# Used to sniff file headers (e.g. the age magic) without downloading the whole
# object or needing the decryption key.
s3_head_bytes() { rclone cat --head "${2:-64}" "$(s3_path "$1")" 2>/dev/null; }

# Like s3_put_stream, but logs the object path + resulting size afterwards.
# Used by the backup scripts so every uploaded file name/size is visible.
put_stream_logged() {                   # $1 = relative path ; reads stdin
    local rel="$1"
    s3_put_stream "$rel"
    local sz; sz="$(s3_size "$rel" 2>/dev/null || true)"
    log "  ↳ uploaded ${rel} ($(human_bytes "${sz:-0}")) -> $(s3_path "$rel")"
}

# --------------------------------------------------------------------------- #
# Encryption streams (stdin -> stdout)                                         #
# --------------------------------------------------------------------------- #
# encrypt_stream appends the correct extension via enc_ext().

enc_ext() {
    case "$BACKUP_ENCRYPTION" in
        age) printf '.age' ;;
        gpg) printf '.gpg' ;;
        none) printf '' ;;
        *) die "unknown BACKUP_ENCRYPTION='$BACKUP_ENCRYPTION'" ;;
    esac
}

# Fail fast at startup if encryption is misconfigured. Without this, an unset
# recipient only surfaces when the first backup runs (encrypt_stream die()s) —
# hours later. Coolify does not reliably enforce the template's ${VAR:?} guard,
# so we enforce it here.
check_encryption_config() {
    case "$BACKUP_ENCRYPTION" in
        age)
            [[ -n "$BACKUP_AGE_RECIPIENT" ]] || die \
"BACKUP_ENCRYPTION=age but BACKUP_AGE_RECIPIENT is empty — every backup would fail to encrypt. \
Generate a key with 'age-keygen', set the public key (age1...) as BACKUP_AGE_RECIPIENT, and keep \
the private key OFFLINE for restores. (Or set BACKUP_ENCRYPTION=none — NOT recommended.)"
            log "encryption: age recipient present ($(printf '%s' "$BACKUP_AGE_RECIPIENT" | cut -c1-12)...)"
            ;;
        gpg)
            [[ -n "$BACKUP_GPG_RECIPIENT" ]] || die \
"BACKUP_ENCRYPTION=gpg but BACKUP_GPG_RECIPIENT is empty — set a gpg key id/email, or use BACKUP_ENCRYPTION=none."
            log "encryption: gpg recipient=${BACKUP_GPG_RECIPIENT}"
            ;;
        none)
            warn "BACKUP_ENCRYPTION=none — backups will be UNENCRYPTED at rest. Only use this if the S3 target is already encrypted."
            ;;
        *)
            die "unknown BACKUP_ENCRYPTION='$BACKUP_ENCRYPTION' (expected: age | gpg | none)"
            ;;
    esac
}

encrypt_stream() {
    case "$BACKUP_ENCRYPTION" in
        age)
            [[ -n "$BACKUP_AGE_RECIPIENT" ]] || die "BACKUP_AGE_RECIPIENT required for age encryption"
            age -r "$BACKUP_AGE_RECIPIENT"
            ;;
        gpg)
            [[ -n "$BACKUP_GPG_RECIPIENT" ]] || die "BACKUP_GPG_RECIPIENT required for gpg encryption"
            gpg --batch --yes --trust-model always --encrypt -r "$BACKUP_GPG_RECIPIENT"
            ;;
        none)
            cat
            ;;
    esac
}

decrypt_stream() {
    case "$BACKUP_ENCRYPTION" in
        age)
            [[ -n "$BACKUP_AGE_IDENTITY_FILE" && -f "$BACKUP_AGE_IDENTITY_FILE" ]] \
                || die "BACKUP_AGE_IDENTITY_FILE must point to the age private key for restore"
            age -d -i "$BACKUP_AGE_IDENTITY_FILE"
            ;;
        gpg)
            gpg --batch --yes --decrypt
            ;;
        none)
            cat
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# Status + alerting                                                            #
# --------------------------------------------------------------------------- #
# Each job writes a per-type marker so healthcheck.sh and the status page can
# report the age of the last success and surface failures.

mark_success() {                        # $1 = job type
    mkdir -p "$STATUS_DIR"
    printf '%s' "$(date -u +%s)" > "${STATUS_DIR}/last_success_$1"
    render_status
}

mark_failure() {                        # $1 = job type, $2 = message
    mkdir -p "$STATUS_DIR"
    printf '%s|%s' "$(date -u +%s)" "$2" > "${STATUS_DIR}/last_failure_$1"
    render_status
    alert "failed" "$1: $2"
}

alert() {                               # $1 = state, $2 = detail
    [[ -n "$ALERT_WEBHOOK" ]] || return 0
    local body
    body=$(printf '{"service":"supabase-backup","prefix":"%s","state":"%s","detail":%s,"time":"%s"}' \
        "$BACKUP_PREFIX" "$1" "$(json_str "$2")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    curl -fsS -m 15 -X POST -H 'Content-Type: application/json' -d "$body" "$ALERT_WEBHOOK" \
        >/dev/null 2>&1 || warn "alert webhook POST failed"
}

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g' | awk '{printf "\"%s\"", $0}'; }

render_status() {
    mkdir -p "$STATUS_DIR"
    {
        echo "Corelix Supabase Backup — ${BACKUP_PREFIX}"
        echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "pitr_enabled: ${PITR_ENABLED}  storage_enabled: ${STORAGE_ENABLED}"
        echo ""
        local f t age
        for f in "$STATUS_DIR"/last_success_*; do
            [[ -e "$f" ]] || continue
            t=$(cat "$f"); age=$(( $(date -u +%s) - t ))
            echo "OK   ${f##*/last_success_}: ${age}s ago"
        done
        for f in "$STATUS_DIR"/last_failure_*; do
            [[ -e "$f" ]] || continue
            echo "FAIL ${f##*/last_failure_}: $(cat "$f")"
        done
    } > "${STATUS_DIR}/index.html" 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
# psql helper (quiet, tuples-only)                                             #
# --------------------------------------------------------------------------- #

psql_scalar() { psql -X -v ON_ERROR_STOP=1 -qtAc "$1"; }

# --------------------------------------------------------------------------- #
# Connectivity diagnostics                                                     #
# --------------------------------------------------------------------------- #
# These answer, verbosely: is the DB container visible? does the port accept?
# does auth succeed? — instead of a silent pg_isready loop.

# Resolve a hostname to IPs for display. Best-effort; never fails the caller.
# Prefer getent (real answer). Fall back to busybox nslookup, but parse ONLY the
# answer section ("Address 1: <ip>") — never the "Address:\t<server>:53" header,
# which would otherwise misreport the DNS server as the host's IP.
resolve_host() {
    local ips
    ips="$(getent hosts "$1" 2>/dev/null | awk '{print $1}')"
    [[ -z "$ips" ]] && ips="$(getent ahosts "$1" 2>/dev/null | awk '{print $1}')"
    [[ -z "$ips" ]] && ips="$(nslookup "$1" 2>/dev/null | awk '/^Address[ ]+[0-9]+:/{print $NF}')"
    printf '%s' "$ips" | awk 'NF' | grep -E '^[0-9a-fA-F:.]+$' | sort -u | tr '\n' ' '
}

# True if a TCP connection to host:port can be opened (bash /dev/tcp).
tcp_open() {
    (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    return 1
}

# Verbose wait-for-DB. Logs, on EVERY attempt, exactly which layer failed
# (DNS / TCP / server-ready / auth) so operators know what to fix. Returns 0
# once a real query succeeds. $1 = max tries (default 60), $2 = delay s (5).
wait_for_db() {
    local tries="${1:-60}" delay="${2:-5}" i ip pgr ver rc
    log "connecting to database ${PGUSER}@${PGHOST}:${PGPORT} (db=${PGDATABASE})"
    ip="$(resolve_host "$PGHOST" 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then log "  DNS: ${PGHOST} -> ${ip}"
    else warn "  DNS: '${PGHOST}' does not resolve yet — is the backup on the SAME Coolify network as Supabase? (enable 'Connect to Predefined Network')"; fi

    for ((i=1; i<=tries; i++)); do
        if ! tcp_open "$PGHOST" "$PGPORT"; then
            log "  [$i/$tries] TCP ${PGHOST}:${PGPORT} refused/unreachable — DB container not up or not on this network yet"
            sleep "$delay"; continue
        fi
        pgr="$(pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" 2>&1)" && rc=0 || rc=$?
        if [[ $rc -ne 0 ]]; then
            log "  [$i/$tries] TCP open, Postgres NOT accepting connections yet: ${pgr}"
            sleep "$delay"; continue
        fi
        ver="$(psql -X -tAc 'SHOW server_version' 2>&1)" && rc=0 || rc=$?
        if [[ $rc -eq 0 ]]; then
            log "  [$i/$tries] CONNECTED — Postgres ${ver// /} as ${PGUSER} (auth OK)"
            return 0
        fi
        log "  [$i/$tries] port open + ready, but AUTH/QUERY FAILED: ${ver}"
        log "        -> check PGPASSWORD (your Supabase SERVICE_PASSWORD_POSTGRES), PGUSER='${PGUSER}', PGDATABASE='${PGDATABASE}'"
        sleep "$delay"
    done
    return 1
}

# One-shot rich diagnostic dump (the `diagnose` command). Non-fatal.
diagnose_db() {
    log "=== database diagnostics ==="
    if ! wait_for_db 1 0; then
        warn "database not reachable — see the attempt above for the failing layer"
        return 1
    fi
    local dbs slots wl
    dbs="$(psql -X -qtAc "SELECT string_agg(datname,', ') FROM pg_database WHERE datistemplate=false" 2>/dev/null || echo '?')"
    wl="$(psql_scalar 'SHOW wal_level' 2>/dev/null || echo '?')"
    log "  databases: ${dbs}"
    log "  wal_level: ${wl} (PITR needs 'replica' or 'logical')"
    if [[ "$PITR_ENABLED" == "true" ]]; then
        slots="$(psql -X -qtAc "SELECT slot_name||' (active='||active||', restart_lsn='||COALESCE(restart_lsn::text,'-')||')' FROM pg_replication_slots WHERE slot_name='${REPLICATION_SLOT}'" 2>/dev/null || true)"
        [[ -n "$slots" ]] && log "  slot: ${slots}" || warn "  slot '${REPLICATION_SLOT}' NOT found — run setup-pitr (init container)"
    fi
    log "=== end database diagnostics ==="
}

# --------------------------------------------------------------------------- #
# S3 / MinIO preflight                                                         #
# --------------------------------------------------------------------------- #
# Proves the backup target actually works: connect + write + read-back + delete.
# Called at startup and by the `preflight` command. die()s on write/read fail.

# Actionable hints printed when the S3 preflight fails. The most common cause is
# the bucket being baked into the endpoint host AND path-style on, which
# addresses the bucket twice (host + path) so writes and reads resolve to
# different keys — the exact symptom of "write OK, read empty".
s3_hint() {
    local host="${BACKUP_S3_ENDPOINT#*://}"; host="${host%%/*}"
    warn "  hints:"
    if [[ "$host" == "${BACKUP_S3_BUCKET}."* ]]; then
        warn "    • Your endpoint host '${host}' already STARTS WITH the bucket name."
        warn "      With path-style on, the bucket is addressed twice (host + path),"
        warn "      so writes and reads land on different keys. Use the REGIONAL"
        warn "      endpoint WITHOUT the bucket, e.g.:"
        warn "        BACKUP_S3_ENDPOINT=https://${host#"${BACKUP_S3_BUCKET}".}"
        warn "      (Scaleway: https://s3.${BACKUP_S3_REGION}.scw.cloud, AWS: https://s3.${BACKUP_S3_REGION}.amazonaws.com)"
    fi
    warn "    • Try flipping BACKUP_S3_FORCE_PATH_STYLE (currently ${BACKUP_S3_FORCE_PATH_STYLE})."
    warn "    • Confirm the access key can BOTH PutObject and GetObject on '${BACKUP_S3_BUCKET}'."
    warn "    • Confirm the region matches the bucket's region ('${BACKUP_S3_REGION}')."
}

s3_preflight() {
    require_backup_target
    log "=== S3 backup-target preflight ==="
    log "  endpoint=${BACKUP_S3_ENDPOINT}"
    log "  bucket=${BACKUP_S3_BUCKET} prefix=${BACKUP_PREFIX} region=${BACKUP_S3_REGION} path_style=${BACKUP_S3_FORCE_PATH_STYLE}"
    log "  encryption=${BACKUP_ENCRYPTION}$( [[ "$BACKUP_ENCRYPTION" == age ]] && printf ' recipient=%s' "${BACKUP_AGE_RECIPIENT:-(unset!)}" )"

    # Early smell test: bucket baked into the endpoint host + path-style.
    local host="${BACKUP_S3_ENDPOINT#*://}"; host="${host%%/*}"
    if [[ "$host" == "${BACKUP_S3_BUCKET}."* && "$BACKUP_S3_FORCE_PATH_STYLE" == "true" ]]; then
        warn "  endpoint host contains the bucket name AND path-style is on — this usually breaks reads (see hints on failure)."
    fi

    local key token got rc attempt errfile
    key=".corelix-preflight/$(ts).$$"
    token="corelix-preflight $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$$"
    errfile="$(mktemp)"

    if printf '%s' "$token" | s3_put_stream "$key" 2>"$errfile"; then
        log "  [1/3] write  OK -> $(s3_path "$key")"
    else
        warn "  write error: $(tr '\n' ' ' < "$errfile")"
        rm -f "$errfile"; s3_hint
        die "S3 WRITE FAILED to ${BACKUP_S3_BUCKET}/${BACKUP_PREFIX} — check keys, endpoint, bucket, region, and write permission."
    fi

    # Read back with a small retry (defensive against brief propagation delays),
    # capturing rclone's real stderr so a failure is diagnosable.
    got=""
    for attempt in 1 2 3; do
        got="$(s3_get_stream "$key" 2>"$errfile")" && rc=0 || rc=$?
        [[ "$got" == "$token" ]] && break
        debug "read-back attempt ${attempt}: rc=${rc} got='${got:-<empty>}' err='$(tr '\n' ' ' < "$errfile")'"
        sleep 1
    done

    if [[ "$got" == "$token" ]]; then
        log "  [2/3] read   OK (round-trip byte-for-byte match)"
    else
        warn "  read-back returned '${got:-<empty>}' (rclone: $(tr '\n' ' ' < "$errfile"))"
        rm -f "$errfile"; s3_hint
        die "S3 READ-BACK FAILED — wrote a probe object but could not read it back identically. Fix the target per the hints above; no backup can run until this passes."
    fi
    rm -f "$errfile"

    s3_delete "$key"
    log "  [3/3] delete OK (cleanup)"
    log "S3 preflight PASSED — connect, write, read, delete all working."
    log "=== end S3 preflight ==="
}

# Verify the Supabase MinIO source is reachable (storage backups read from it).
minio_preflight() {
    [[ "$STORAGE_ENABLED" == "true" ]] || { log "storage disabled — skipping MinIO preflight"; return 0; }
    if [[ -z "$MINIO_ACCESS_KEY" || -z "$MINIO_SECRET_KEY" ]]; then
        warn "MinIO credentials not set (MINIO_ACCESS_KEY/MINIO_SECRET_KEY) — storage backups will fail until provided"
        return 0
    fi
    log "MinIO source preflight: endpoint=${MINIO_ENDPOINT} bucket=${STORAGE_BUCKET}"
    if rclone lsf "minio:${STORAGE_BUCKET}" >/dev/null 2>&1; then
        local c; c="$(rclone lsf "minio:${STORAGE_BUCKET}" 2>/dev/null | wc -l | tr -d ' ')"
        log "  MinIO OK — bucket '${STORAGE_BUCKET}' reachable (${c} top-level entrie(s))"
    else
        warn "  MinIO NOT reachable or bucket '${STORAGE_BUCKET}' inaccessible — storage backups will fail. Check MINIO_ENDPOINT/creds/bucket."
    fi
}

# Effective-configuration banner (secrets redacted). Printed at startup.
log_config_banner() {
    log "=== effective configuration ==="
    log "  DB        : ${PGUSER}@${PGHOST}:${PGPORT} db=${PGDATABASE} password=$(redact "$PGPASSWORD")"
    log "  databases : ${BACKUP_DATABASES}"
    log "  PITR      : enabled=${PITR_ENABLED} setup=${PITR_SETUP} slot=${REPLICATION_SLOT} cidr=${REPLICATION_CIDR}"
    log "  storage   : enabled=${STORAGE_ENABLED} minio=${MINIO_ENDPOINT} bucket=${STORAGE_BUCKET} access=$(redact "$MINIO_ACCESS_KEY")"
    log "  config    : enabled=${CONFIG_ENABLED} dbconfig_dir=${DBCONFIG_DIR} (mounted=$([[ -d "$DBCONFIG_DIR" ]] && echo yes || echo no))"
    log "  target S3 : ${BACKUP_S3_ENDPOINT} bucket=${BACKUP_S3_BUCKET} prefix=${BACKUP_PREFIX} region=${BACKUP_S3_REGION}"
    log "  encryption: ${BACKUP_ENCRYPTION} recipient=${BACKUP_AGE_RECIPIENT:-${BACKUP_GPG_RECIPIENT:-(none)}}"
    log "  retention : daily=${RETAIN_DAILY} weekly=${RETAIN_WEEKLY} monthly=${RETAIN_MONTHLY} basebackups=${RETAIN_BASEBACKUPS}"
    log "  source img: ${SOURCE_IMAGE_TAG}"
    log "=== end configuration ==="
}

# Regenerate the RESTORE.md runbook in the backup folder. Non-fatal: a runbook
# failure must never fail the backup that triggered it.
update_runbook() {
    [[ "${RUNBOOK_ENABLED:-true}" == "true" ]] || return 0
    log "updating restore runbook -> $(s3_path RESTORE.md)"
    if "${LIB_DIR}/restore-runbook.sh"; then
        log "  runbook updated"
    else
        warn "  runbook generation failed (non-fatal — backup itself succeeded)"
    fi
}

configure_rclone

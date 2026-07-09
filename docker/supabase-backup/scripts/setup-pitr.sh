#!/usr/bin/env bash
#
# setup-pitr.sh — one-shot init: provision the physical replication slot and the
# pg_hba.conf replication line that pg_receivewal needs. Idempotent.
#
# Runs entirely against the DB over SQL (superuser: supabase_admin), so the
# sidecar does not need to mount the Postgres data directory.
#
#   PITR_SETUP=auto    -> provision slot + hba line (default)
#   PITR_SETUP=manual  -> no-op (operator provisions by hand; see README)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_TAG="setup-pitr"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ "$PITR_ENABLED" != "true" ]]; then
    log "PITR disabled — nothing to set up"; exit 0
fi
if [[ "$PITR_SETUP" == "manual" ]]; then
    log "PITR_SETUP=manual — skipping automatic provisioning (operator handles slot + pg_hba)"
    exit 0
fi

log_config_banner
# Verbose wait: logs DNS / TCP / server-ready / auth for each attempt so a stuck
# init container tells you WHY (wrong password? wrong network? DB still booting?).
if ! wait_for_db 60 5; then
    die "database ${PGHOST}:${PGPORT} not reachable after 5 minutes — see the per-attempt reason above (DNS/TCP/auth). PITR setup aborted."
fi

# 1) Physical replication slot (created reserved so WAL is retained immediately).
log "checking for physical replication slot '${REPLICATION_SLOT}'"
existing=$(psql_scalar "SELECT 1 FROM pg_replication_slots WHERE slot_name = '${REPLICATION_SLOT}'" || true)
if [[ "$existing" == "1" ]]; then
    log "replication slot '${REPLICATION_SLOT}' already exists — reusing"
else
    psql_scalar "SELECT pg_create_physical_replication_slot('${REPLICATION_SLOT}', true)" >/dev/null
    log "created physical replication slot '${REPLICATION_SLOT}' (reserved)"
fi

# 2) Ensure a 'host replication <user> <cidr> scram-sha-256' pg_hba rule exists.
#    We check pg_hba_file_rules, then append via COPY ... TO PROGRAM (superuser)
#    to the server's actual hba_file, and reload.
has_repl=$(psql_scalar "
    SELECT 1 FROM pg_hba_file_rules
    WHERE type = 'host'
      AND database @> ARRAY['replication']
      AND ('${PGUSER}' = ANY(user_name) OR 'all' = ANY(user_name))
    LIMIT 1" || true)

if [[ "$has_repl" == "1" ]]; then
    log "replication pg_hba rule already present"
else
    hba_file=$(psql_scalar "SHOW hba_file")
    [[ -n "$hba_file" ]] || die "could not resolve hba_file"
    line="host replication ${PGUSER} ${REPLICATION_CIDR} scram-sha-256"
    log "appending replication rule to ${hba_file}: ${line}"
    # COPY the literal line to a program that appends it to the hba file.
    # quote_literal guards the path; the SELECT provides the exact line.
    psql -X -v ON_ERROR_STOP=1 -qtAc \
        "COPY (SELECT '# added by corelix supabase-backup') TO PROGRAM 'cat >> $hba_file'"
    psql -X -v ON_ERROR_STOP=1 -qtAc \
        "COPY (SELECT '${line}') TO PROGRAM 'cat >> $hba_file'"
    psql_scalar "SELECT pg_reload_conf()" >/dev/null

    # Verify the reload picked it up.
    ok=$(psql_scalar "
        SELECT 1 FROM pg_hba_file_rules
        WHERE type='host' AND database @> ARRAY['replication']
          AND ('${PGUSER}' = ANY(user_name) OR 'all' = ANY(user_name)) LIMIT 1" || true)
    [[ "$ok" == "1" ]] || die "replication rule not active after reload — check pg_hba_file_rules for errors"
    log "replication pg_hba rule active"
fi

# 3) Sanity: confirm wal_level supports streaming (Supabase default is 'replica').
wal_level=$(psql_scalar "SHOW wal_level")
[[ "$wal_level" == "replica" || "$wal_level" == "logical" ]] \
    || warn "wal_level='${wal_level}' — pg_receivewal needs 'replica' or higher"

log "PITR setup complete"

# corelix-supabase-backup (sidecar image)

Source for the backup sidecar image used by the
[`supabase-backup`](../../templates/compose/supabase-backup.yaml) Coolify template.
Published to `ghcr.io/corelix-io/coolify-enhanced-templates/supabase-backup`.

It gives self-hosted Supabase **best-practice, minimum-loss backups**:

- **Tier 1 (logical):** `pg_dumpall --roles-only` + per-DB `pg_dump -Fc`, MinIO
  storage mirror, and the pgsodium key / secrets manifest.
- **Tier 2 (PITR):** `pg_basebackup` + continuous `pg_receivewal` streaming
  through a physical replication slot — no changes to the Supabase Postgres
  image. RPO ≈ seconds.
- Standalone `age`/`gpg` encryption to any S3-compatible target; GFS retention;
  scheduled integrity verification; slot-lag healthcheck; webhook alerts.

## Observability

The sidecar is verbose by design (`LOG_LEVEL=info` default; `debug` adds rclone
transfer logs). On startup it:

1. prints an **effective-config banner** (secrets redacted);
2. **waits for the DB** reporting the failing layer on every attempt —
   DNS / TCP / server-ready / **auth** — instead of a silent `pg_isready` loop
   (fixes the opaque "connecting to database" hang);
3. runs an **S3 preflight**: connect → write a probe object → read it back →
   delete. A broken target fails loudly at boot, not 6 hours later;
4. checks the **MinIO source** is reachable (for storage backups);
5. writes an initial **`RESTORE.md`** runbook to the backup folder.

Each backup logs every uploaded object's **name + size**, and after every cycle
regenerates **`RESTORE.md`** — a detailed empty-machine-to-working-Supabase
restore runbook that reflects the newest snapshots (`RUNBOOK_ENABLED=false` to
skip).

## Build

```bash
docker build -t ghcr.io/corelix-io/coolify-enhanced-templates/supabase-backup:15 .
# Different Postgres major (match your supabase/postgres):
docker build --build-arg BASE_IMAGE=postgres:16-alpine -t ...:16 .
```

CI builds and pushes on changes to this directory —
`.github/workflows/build-supabase-backup-image.yml`.

## Commands (via the entrypoint)

| Command | Purpose |
|---|---|
| `run` (default) | Long-running: WAL stream + cron scheduler + status page |
| `setup-pitr` | One-shot init: create replication slot + `pg_hba` line |
| `backup-logical` / `backup-basebackup` / `backup-storage` / `backup-config` | Run a backup job now |
| `ship-wal` / `prune` | WAL shipping / retention |
| `verify` | Backup trust check — **structural** (keyless) by default; **deep** decrypt+`pg_restore --list` when a private key is present or `VERIFY_DECRYPT=true` |
| `restore-logical [SNAPSHOT] [DB]` | Guided logical restore (roles → template0 → data) |
| `restore-pitr --target-time "…"` | Prepare a point-in-time recovery |
| `preflight` | Test the S3 target (connect + write + read-back + delete) and MinIO source |
| `diagnose` | DB reachability/auth + replication slot + S3/MinIO checks (one-shot) |
| `gen-runbook` | (Re)generate `RESTORE.md` in the backup folder now |
| `healthcheck` | Container healthcheck |

Troubleshooting a stuck deploy:

```bash
# why can't it reach the DB / S3? (run in the same project/network)
docker compose run --rm supabase-backup diagnose
# or just prove the backup target works:
docker compose run --rm supabase-backup preflight
```

### Common config mistakes the preflight catches

- **`S3 READ-BACK FAILED` (write OK, read empty).** Almost always the endpoint
  has the **bucket baked into the host** (e.g. `https://<bucket>.s3.<region>.scw.cloud`)
  while path-style is on, addressing the bucket twice. Use the **regional
  endpoint without the bucket** (`https://s3.<region>.scw.cloud`), or set
  `BACKUP_S3_FORCE_PATH_STYLE=false`. The failure prints the exact corrected value.
- **`BACKUP_AGE_RECIPIENT is empty`.** With `BACKUP_ENCRYPTION=age` (default) you
  must provide an age public key (`age-keygen`); the container now fails fast at
  startup instead of only when the first backup runs.

### age encryption — where the keys live

`age` is asymmetric. `age-keygen` produces a **public** key (`age1…`) and a
**private** key (`AGE-SECRET-KEY-1…`, saved in the key file).

- **`BACKUP_AGE_RECIPIENT`** = the **public** key. It goes on the running backup
  service and is used to **encrypt** (`age -r`). Safe to expose. The backup box
  therefore **cannot decrypt its own backups** — that is the security guarantee.
- **`BACKUP_AGE_IDENTITY_FILE`** = a path to the **private** key file. Used only to
  **decrypt** during `restore-*` and deep `verify`. **Keep the private key OFFLINE**
  (password manager / vault); never set it on the always-on backup service. Lose it
  and every backup is permanently unrecoverable.

Because of this, the scheduled `verify` job is **structural** by design (presence +
size + age header) — it cannot decrypt without the private key. To periodically
prove a backup decrypts and restores, run `verify` on a trusted machine with the
key mounted read-only:

```bash
docker run --rm \
  -e BACKUP_ENCRYPTION=age -e BACKUP_AGE_IDENTITY_FILE=/keys/age.key -e VERIFY_DECRYPT=true \
  -e BACKUP_S3_ENDPOINT -e BACKUP_S3_BUCKET -e BACKUP_S3_REGION -e BACKUP_S3_FORCE_PATH_STYLE \
  -e BACKUP_PREFIX -e BACKUP_S3_ACCESS_KEY -e BACKUP_S3_SECRET_KEY -e PGPASSWORD=unused \
  -v /path/age.key:/keys/age.key:ro \
  ghcr.io/corelix-io/coolify-enhanced-templates/supabase-backup:15 verify
```

See the template file and `docs/features/supabase-backup-template/` in the
platform repo for the full env contract, deployment, and restore runbook.

# Corelix self-hosted Supabase backup sidecar.
#
# Base is the official Postgres 15 Alpine image so the client tools
# (pg_dump, pg_dumpall, pg_basebackup, pg_receivewal, pg_restore, psql) match
# the Supabase server major (Coolify pins supabase/postgres 15.x). Bump the
# major in lockstep with Coolify's Supabase template.
ARG BASE_IMAGE=postgres:15-alpine
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="corelix-supabase-backup" \
      org.opencontainers.image.description="PITR + logical backups for self-hosted Supabase on Coolify" \
      org.opencontainers.image.source="https://github.com/corelix-io/coolify-enhanced-templates" \
      org.opencontainers.image.licenses="Apache-2.0"

# Tools: age/gpg (encryption), rclone (S3 transport + MinIO mirror), dcron
# (scheduler), darkhttpd (status page), tini (PID 1 reaping), plus GNU
# tar/coreutils and curl for webhooks. (WAL shipper uses a mkdir mutex — no
# flock dependency.)
RUN set -eux; \
    apk add --no-cache \
        bash coreutils tar gzip tzdata ca-certificates curl \
        age gnupg rclone dcron darkhttpd tini; \
    mkdir -p /scripts /staging/wal /staging/www /etc/crontabs; \
    : > /etc/crontabs/root

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

ENV STAGING_DIR=/staging \
    STATUS_DIR=/staging/www \
    WAL_DIR=/staging/wal \
    STATUS_PORT=8080 \
    PITR_ENABLED=true \
    PITR_SETUP=auto

# Run as root: the sidecar reads the mounted db-config volume and manages cron.
USER root
WORKDIR /scripts

EXPOSE 8080
ENTRYPOINT ["/sbin/tini", "--", "/scripts/entrypoint.sh"]
CMD ["run"]

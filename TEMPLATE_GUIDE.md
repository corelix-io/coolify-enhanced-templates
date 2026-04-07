# Creating Custom Coolify Service Templates

This guide explains how to create Docker Compose templates compatible with [Coolify](https://coolify.io) for this repository. It is intended for both human contributors and AI agents.

> **Sources:** This guide is based on the official [Coolify Service Contribution Docs](https://github.com/coollabsio/coolify-docs/blob/next/docs/get-started/contribute/service.md), the [Coolify Docker Compose Docs](https://github.com/coollabsio/coolify-docs/blob/next/docs/knowledge-base/docker/compose.md), and the [Coolify Enhanced custom-templates documentation](https://github.com/amirhmoradi/coolify-enhanced/blob/main/docs/custom-templates.md).

---

## Table of Contents

1. [Overview](#overview)
2. [Template File Structure](#template-file-structure)
3. [Header Metadata](#header-metadata)
4. [Template Tiers](#template-tiers)
5. [Services Section](#services-section)
6. [Environment Variables](#environment-variables)
7. [Magic Environment Variables](#magic-environment-variables)
8. [Storage and Volumes](#storage-and-volumes)
9. [Health Checks](#health-checks)
10. [Networking](#networking)
11. [Database Classification](#database-classification)
12. [Testing Your Template](#testing-your-template)
13. [Validation](#validation)
14. [Submitting Your Template](#submitting-your-template)
15. [Complete Example](#complete-example)
16. [Reference: Existing Templates](#reference-existing-templates)
17. [Common Pitfalls](#common-pitfalls)

---

## Overview

Coolify service templates are standard Docker Compose files enhanced with Coolify-specific features. The Docker Compose file is **the single source of truth** — configuration that would normally be done through the Coolify UI must be defined directly in the compose file.

Templates in this repository live under `templates/compose/` and follow a consistent naming convention:

- `<service-name>.yaml` — primary template
- `<service-name>-<variant>.yaml` — variants (e.g., `pocketid-pg.yaml`, `pocketid-sqlite.yaml`)

This repository is part of the [Corelix Platform](https://corelix.io) and is published to two public repos:
- **Free community edition:** [`corelix-io/coolify-enhanced-templates`](https://github.com/corelix-io/coolify-enhanced-templates) (premium templates removed)
- **Full edition:** [`corelix-io/service-templates`](https://github.com/corelix-io/service-templates) (all templates, for subscribers)

---

## Template File Structure

Every template follows this structure:

```yaml
# documentation: <url>
# slogan: <one-line description>
# tags: <comma-separated tags>
# category: <category>
# logo: svgs/<service-name>.svg
# port: <primary service port>
# author: @amirhmoradi
# repository: https://github.com/amirhmoradi/coolify-enhanced-templates

services:
  <service-name>:
    image: <image>:<tag>
    environment:
      - SERVICE_FQDN_<NAME>_<PORT>
      - VAR=${VAR:-default}
    volumes:
      - <volume>:<path>
    depends_on:
      <dependency>:
        condition: service_healthy
    healthcheck:
      test: [...]
      interval: <duration>
      timeout: <duration>
      retries: <number>

  # Supporting services (databases, caches, etc.)
  <db-service>:
    image: <image>:<tag>
    ...

volumes:
  <volume-name>:
```

---

## Header Metadata

Every template **must** begin with comment-based metadata:

```yaml
# documentation: https://docs.example.com/
# slogan: A brief description of your service.
# tags: tag1,tag2,tag3
# category: ai
# logo: svgs/myservice.svg
# port: 8080
# author: @amirhmoradi
# repository: https://github.com/amirhmoradi/coolify-enhanced-templates
```

### Required Headers

| Field | Description |
|-------|-------------|
| `documentation` | URL to the service's official documentation. `?utm_source=coolify.io` is appended automatically. |
| `slogan` | Short one-line description of the service (under 80 characters). |
| `tags` | Comma-separated keywords for search/categorization. |
| `port` | The main port users access the service on. **Always specify.** Coolify's Caddy proxy cannot auto-detect ports. |
| `author` | GitHub handle of the template author. |
| `repository` | URL to this repository. |

### Recommended Headers (Coolify Enhanced)

| Field | Description |
|-------|-------------|
| `category` | Category for filtering in the UI. Multiple: `category: monitoring,devops`. |
| `logo` | Path to SVG logo (relative from repo root) or absolute URL. SVG preferred. |

**Available categories:** `ai`, `monitoring`, `cms`, `development`, `database`, `devops`, `analytics`, `communication`, `security`, `storage`, `automation`, `media`, `productivity`.

### Optional Headers

| Field | Description |
|-------|-------------|
| `tier` | `premium` for paid-only templates. Omit or set `free` for community. See [Template Tiers](#template-tiers). |
| `type` | `database` or `application` — overrides automatic classification for all services. See [Database Classification](#database-classification). |
| `env_file` | Path to `.env` file (relative to template folder) for default environment variables. |
| `ignore` | Set to `true` to exclude this file from the template list (e.g. WIP templates). |
| `minversion` | Minimum Coolify version required (e.g., `4.0.0-beta.300`). Defaults to `0.0.0`. |

---

## Template Tiers

Templates can be **free** (community) or **premium** (paid):

| Tier | Header | Published to | Description |
|------|--------|-------------|-------------|
| Free | `# tier: free` or omitted | `corelix-io/coolify-enhanced-templates` | Open source, available to everyone |
| Premium | `# tier: premium` | `corelix-io/service-templates` only | Removed from the free build; listed in `PREMIUM.md` |

- **Default is free.** Templates without a `# tier:` header are free.
- Premium templates are **deleted** from the free edition. A `PREMIUM.md` catalog lists what's available with descriptions and links to subscribe.
- When adding a premium template, also add an entry to `PREMIUM.md` and add the SVG logo to `.free-edition-ignore`.
- Both editions are published automatically by the CI workflow at `.github/workflows/publish-templates.yml` (at the project root).

---

## Services Section

Define all services under the `services:` key. A template typically includes:

1. **Primary service** — the main application
2. **Supporting services** — databases (PostgreSQL, Redis), proxies, workers, etc.

### Primary Service Pattern

```yaml
services:
  myapp:
    image: vendor/myapp:1.0
    environment:
      - SERVICE_FQDN_MYAPP_3000
      - DATABASE_URL=postgres://$SERVICE_USER_POSTGRES:$SERVICE_PASSWORD_POSTGRES@postgres:5432/mydb
    volumes:
      - myapp-data:/app/data
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

### Database Service Patterns

**PostgreSQL:**

```yaml
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: $SERVICE_USER_POSTGRES
      POSTGRES_PASSWORD: $SERVICE_PASSWORD_POSTGRES
      POSTGRES_DB: mydb
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "$SERVICE_USER_POSTGRES", "-d", "mydb"]
      interval: 10s
      timeout: 5s
      retries: 5
```

**Redis:**

```yaml
  redis:
    image: redis:7-alpine
    environment:
      REDIS_PASSWORD: $SERVICE_PASSWORD_REDIS
    volumes:
      - redis-data:/data
    command: redis-server --requirepass "$SERVICE_PASSWORD_REDIS"
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "$SERVICE_PASSWORD_REDIS", "ping"]
      interval: 5s
      timeout: 10s
      retries: 20
```

### Worker / Background Service Pattern

For services that share the same image in a different mode:

```yaml
  worker:
    image: vendor/myapp:1.0
    command: ["worker", "--queue", "default"]
    environment:
      <<: *shared-env
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "celery inspect ping || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
```

### YAML Anchors for Shared Environment

For complex templates with many shared variables across services:

```yaml
x-shared-env: &shared-env
  DB_HOST: ${DB_HOST:-db}
  DB_PORT: ${DB_PORT:-5432}
  DB_PASSWORD: $SERVICE_PASSWORD_POSTGRES
  REDIS_URL: redis://:$SERVICE_PASSWORD_REDIS@redis:6379/0
  SECRET_KEY: $SERVICE_PASSWORD_64_SECRETKEY

services:
  api:
    image: vendor/api:1.0
    environment:
      <<: *shared-env
      MODE: api

  worker:
    image: vendor/api:1.0
    environment:
      <<: *shared-env
      MODE: worker
```

See `dify.yaml` for the canonical example of this pattern.

---

## Environment Variables

Coolify auto-detects environment variables in compose files and displays them in the UI.

### Syntax

| Syntax | Behavior |
|--------|----------|
| `HARDCODED_VALUE=hello` | Not visible in UI, hardcoded |
| `${VAR}` | Editable in UI, initially empty |
| `${VAR:-default}` | Editable in UI, prefilled with `default` |
| `${VAR:?}` | **Required** — deployment fails if not set |
| `${VAR:?default}` | Required with default value shown in UI |

### Best Practices

- Use `${VAR:?}` for settings users **must** configure (API keys, domains, SMTP)
- Use `${VAR:-default}` for settings with sensible defaults
- Use hardcoded values for internal settings that should not change
- Group related variables with comments

```yaml
environment:
  # Required - user must provide
  - API_KEY=${API_KEY:?}
  - SMTP_HOST=${SMTP_HOST:?}

  # Optional with defaults
  - LOG_LEVEL=${LOG_LEVEL:-info}
  - CACHE_TTL=${CACHE_TTL:-3600}

  # Internal - not exposed in UI
  - INTERNAL_PORT=3000
```

### Shared Environment from Coolify

Reference values from Coolify's shared environment section:

```yaml
- MY_VAR={{environment.SHARED_VARIABLE}}
```

---

## Magic Environment Variables

Coolify generates special dynamic variables using the naming pattern `SERVICE_<TYPE>_<IDENTIFIER>`. These are the core mechanism for automatic secret generation and service URL routing.

### Types

| Pattern | Purpose | Example Value |
|---------|---------|---------------|
| `SERVICE_FQDN_<NAME>_<PORT>` | Domain + port routing | Sets up domain proxy to container port |
| `SERVICE_URL_<NAME>` | Full URL of the service | `http://myapp-abc123.example.com` |
| `SERVICE_URL_<NAME>_<PORT>` | Full URL with specific port | `http://myapp-abc123.example.com:3000` |
| `SERVICE_USER_<NAME>` | Random 16-char username | `xKq8mP2nL5vR9wYt` |
| `SERVICE_PASSWORD_<NAME>` | Random password | `aB3$kL9mN2pQ5rSt` |
| `SERVICE_PASSWORD_64_<NAME>` | Random 64-char password | (64 characters) |
| `SERVICE_BASE64_<NAME>` | Random Base64-encoded 32-char string | `dGhpcyBpcyBhIHRlc3Q=` |
| `SERVICE_BASE64_64_<NAME>` | Random Base64-encoded 64-char string | (longer base64) |
| `SERVICE_BASE64_128_<NAME>` | Random Base64-encoded 128-char string | (even longer base64) |

### Usage Rules

1. **FQDN variables** are placed standalone in the environment list (no `=` sign) to register the service with Coolify's proxy:

   ```yaml
   environment:
     - SERVICE_FQDN_MYAPP_3000
   ```

2. **Password/User variables** are referenced with `$` prefix in other variables:

   ```yaml
   environment:
     POSTGRES_USER: $SERVICE_USER_POSTGRES
     POSTGRES_PASSWORD: $SERVICE_PASSWORD_POSTGRES
   ```

3. **Reusing generated values** across services — reference the same variable name:

   ```yaml
   services:
     app:
       environment:
         - DB_PASSWORD=$SERVICE_PASSWORD_POSTGRES
     postgres:
       environment:
         - POSTGRES_PASSWORD=$SERVICE_PASSWORD_POSTGRES
   ```

4. **Port identifiers** use hyphens (not underscores) when service names include ports:

   ```yaml
   # Correct — port is parsed correctly
   - SERVICE_URL_MY-APP_8080

   # Wrong — Coolify misparses the port
   - SERVICE_URL_MY_APP_8080
   ```

5. **Multiple distinct secrets:** For apps that need many long random values, use distinct magic variable names so Coolify generates a unique value for each:

   ```yaml
   - SECRET_KEY=$SERVICE_PASSWORD_64_SECRETKEY
   - INNER_API_KEY=$SERVICE_PASSWORD_64_INNERAPIKEY
   - PLUGIN_KEY=$SERVICE_PASSWORD_64_PLUGINKEY
   - SANDBOX_KEY=$SERVICE_PASSWORD_64_SANDBOXKEY
   ```

---

## Storage and Volumes

### Named Volumes (Recommended)

Use named volumes for persistent data. Coolify manages these automatically:

```yaml
services:
  myapp:
    volumes:
      - app-data:/app/data

volumes:
  app-data:
```

### Creating Directories

Use Coolify's `is_directory` flag to create empty directories:

```yaml
volumes:
  - type: bind
    source: ./srv
    target: /srv
    is_directory: true
```

### Creating Files with Content

Use the `content` key to create configuration files inline — no separate repo files needed:

```yaml
volumes:
  - type: bind
    source: ./config/app.conf
    target: /etc/app/app.conf
    read_only: true
    content: |
      [server]
      port = 3000
      host = 0.0.0.0
```

This is essential for injecting nginx configs, squid proxy configs, init scripts, entrypoints, and other configuration files. The `source:` field is still required as a virtual path even though the file is generated from `content:`.

### Docker Compose Configs (Alternative)

```yaml
services:
  myapp:
    configs:
      - source: init-script
        target: /docker-entrypoint-initdb.d/init.sql

configs:
  init-script:
    content: |
      CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY);
```

---

## Health Checks

Every long-running service **must** include a health check. Health checks enable `depends_on` with `condition: service_healthy` and allow Coolify to monitor service status.

### Common Patterns

**HTTP endpoint:**

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 40s
```

**PostgreSQL:**

```yaml
healthcheck:
  test: ["CMD", "pg_isready", "-U", "$SERVICE_USER_POSTGRES", "-d", "mydb"]
  interval: 10s
  timeout: 5s
  retries: 5
```

**Redis:**

```yaml
healthcheck:
  test: ["CMD", "redis-cli", "-a", "$SERVICE_PASSWORD_REDIS", "ping"]
  interval: 5s
  timeout: 10s
  retries: 20
```

**TCP port check:**

```yaml
healthcheck:
  test: ["CMD-SHELL", "bash -c ':> /dev/tcp/127.0.0.1/8080' || exit 1"]
  interval: 5s
  timeout: 5s
  retries: 10
```

**wget (when curl is not available):**

```yaml
healthcheck:
  test: ["CMD", "wget", "--spider", "-q", "http://localhost:3000"]
  interval: 30s
  timeout: 10s
  retries: 3
```

### Excluding from Health Checks

For services that run once and exit (migrations, init containers, permission fixups), use `exclude_from_hc: true` so Coolify does not wait for them to become healthy:

```yaml
services:
  init_permissions:
    image: busybox:latest
    command: ["sh", "-c", "chown -R 1001:1001 /data"]
    volumes:
      - app-data:/data
    restart: "no"
    exclude_from_hc: true
```

---

## Networking

### Default Behavior

- All services in a compose stack share a private network by default
- Services reference each other using service names as hostnames (e.g., `http://postgres:5432`)
- Services without a domain or port mapping remain private

### Domain Routing

The `SERVICE_FQDN_<NAME>_<PORT>` variable tells Coolify to route external traffic to the specified container port:

```yaml
environment:
  - SERVICE_FQDN_MYAPP_3000   # Routes domain traffic to container port 3000
```

### Direct Port Mapping

Use `ports` to expose a service directly on the host (bypasses the proxy):

```yaml
ports:
  - "3000:3000"        # Exposed on all interfaces
  - "127.0.0.1:3000:3000"  # Localhost only
```

**Warning:** Direct port mapping bypasses Coolify's proxy configuration and may unintentionally expose private services.

### Internal Networks

For security-sensitive services (e.g., SSRF proxies, sandboxes), create isolated networks:

```yaml
services:
  sandbox:
    networks:
      - internal_network
      - default

networks:
  internal_network:
    driver: bridge
    internal: true   # No external access
```

See `dify.yaml` for a production example with `ssrf_proxy_network`.

### Cross-Stack Communication

To connect services across different Coolify stacks:

1. Enable "Connect to Predefined Network" in Coolify service settings
2. Services are renamed to `<name>-<uuid>` to prevent collisions
3. Reference other services using their renamed identifier

---

## Database Classification

Coolify classifies each service as either a **database** or an **application**. Databases get features like "Make Publicly Available" (TCP proxy), scheduled backups, and database import. Coolify Enhanced expands automatic recognition to 50+ database images, but for custom or uncommon databases you may need explicit classification.

### Template-Level

Add `# type: database` to classify **all services** as databases:

```yaml
# type: database

services:
  memgraph:
    image: memgraph/memgraph:latest
```

### Per-Service Labels

For mixed templates (database + admin UI), use Docker labels on individual services:

```yaml
services:
  memgraph:
    image: memgraph/memgraph:latest
    labels:
      coolify.database: "true"

  memgraph-lab:
    image: memgraph/lab:latest
    labels:
      coolify.database: "false"    # Web UI, not a database
```

Per-service labels **always win** over the template-level `# type:` header.

### Multi-Port Proxy

Databases with multiple ports can declare them via the `coolify.proxyPorts` label. This enables a per-port proxy UI in Coolify:

```yaml
services:
  memgraph:
    image: memgraph/memgraph:latest
    labels:
      coolify.database: "true"
      coolify.proxyPorts: "7687:bolt,7444:log-viewer"
```

**Format:** `"internalPort:label,internalPort:label,..."`

**The label name is case-sensitive:** must be `coolify.proxyPorts` (camelCase P), not `coolify.proxyports`.

### Label Formats

Both Docker Compose label formats are supported:

```yaml
# Map format
labels:
  coolify.database: "true"

# Array format
labels:
  - coolify.database=true
```

Boolean parsing is flexible: accepts `true/false`, `1/0`, `yes/no`, `on/off` (case-insensitive).

---

## Testing Your Template

1. Open your **Coolify Dashboard**
2. Go to **Projects** and select or create a project
3. Click **+ Add New Resource**
4. Choose **Docker Compose Empty**
5. Paste your template YAML content
6. Click **Save**
7. Configure any required environment variables in the UI
8. Click **Deploy**

Verify that:

- All services start successfully
- Health checks pass (green status in the UI)
- The main service is accessible via its domain
- Environment variables appear correctly in the UI
- Required variables prevent deployment when empty
- Database services show backup/proxy options if classified

---

## Validation

Run the template validation script before submitting:

```bash
# Validate all templates
./scripts/validate-templates.sh

# Validate a specific template
./scripts/validate-templates.sh templates/compose/myservice.yaml

# List all templates with tier info
./scripts/validate-templates.sh --list
```

The validator checks:
- Required headers (`documentation`, `slogan`, `tags`, `port`)
- Recommended headers (`category`, `logo`)
- `services:` section present
- Health checks on all long-running services
- No `:latest` tag on database images
- `SERVICE_FQDN_*` or `SERVICE_URL_*` present
- Valid `tier` value (if present)
- Logo file exists (if relative path)

---

## Submitting Your Template

### To This Repository

1. Create your `<service-name>.yaml` file under `templates/compose/`
2. Follow the naming conventions:
   - Lowercase, hyphens as separators
   - Use suffixes for variants: `-pg`, `-sqlite`, `-basic`, `-production`
3. Add an SVG logo to `svgs/<service-name>.svg`
4. Run `./scripts/validate-templates.sh templates/compose/<service-name>.yaml`
5. Open a Pull Request with:
   - The new template file
   - The SVG logo
   - An update to `README.md` adding the service to the list
   - If premium: `# tier: premium` header + entry in `PREMIUM.md` + SVG in `.free-edition-ignore`

### To Coolify Upstream (Optional)

If you want to submit directly to Coolify:

1. Add your template to `/templates/compose` in the [Coolify repository](https://github.com/coollabsio/coolify)
2. Include an SVG logo in the `svgs` folder (filename must match the service name)
3. Submit a PR to the main repository
4. After merge, add documentation to the [coolify-docs](https://github.com/coollabsio/coolify-docs) repository

---

## Complete Example

Here is a complete template for a hypothetical service with PostgreSQL and Redis:

```yaml
# documentation: https://docs.example.com/
# slogan: An example service with PostgreSQL and Redis
# tags: example,web,api,postgres,redis
# category: development
# logo: svgs/example.svg
# port: 3000
# author: @amirhmoradi
# repository: https://github.com/amirhmoradi/coolify-enhanced-templates

services:
  myapp:
    image: vendor/myapp:1.0
    environment:
      # Coolify FQDN routing
      - SERVICE_FQDN_MYAPP_3000
      # Database
      - DATABASE_URL=postgres://$SERVICE_USER_POSTGRES:$SERVICE_PASSWORD_POSTGRES@postgres:5432/myapp
      # Redis
      - REDIS_URL=redis://:$SERVICE_PASSWORD_REDIS@redis:6379/0
      # Required settings
      - SECRET_KEY=$SERVICE_BASE64_64_SECRET
      - ADMIN_EMAIL=${ADMIN_EMAIL:?}
      # Optional settings
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - MAX_UPLOAD_SIZE=${MAX_UPLOAD_SIZE:-10M}
    volumes:
      - myapp-data:/app/data
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: $SERVICE_USER_POSTGRES
      POSTGRES_PASSWORD: $SERVICE_PASSWORD_POSTGRES
      POSTGRES_DB: myapp
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "$SERVICE_USER_POSTGRES", "-d", "myapp"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    environment:
      REDIS_PASSWORD: $SERVICE_PASSWORD_REDIS
    volumes:
      - redis-data:/data
    command: redis-server --requirepass "$SERVICE_PASSWORD_REDIS"
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "$SERVICE_PASSWORD_REDIS", "ping"]
      interval: 5s
      timeout: 10s
      retries: 20

volumes:
  myapp-data:
  postgres-data:
  redis-data:
```

---

## Reference: Existing Templates

Study these existing templates for patterns and best practices:

| Template | Complexity | Notable Patterns |
|----------|-----------|-----------------|
| `chartdb.yaml` | Minimal | Single service, no dependencies |
| `corsproxy.yaml` | Simple | Single service, `ports:` instead of FQDN |
| `pocketid-sqlite.yaml` | Simple | SQLite-based, minimal setup |
| `vaultwarden-pg.yaml` | Medium | App + PostgreSQL |
| `planka.yaml` | Medium | App + PostgreSQL, SMTP, S3 config |
| `memgraph.yaml` | Medium | `# type: database`, `coolify.proxyPorts`, multi-port proxy |
| `vikunja.yaml` | Medium | Init container, `content:` bind mount for config, `exclude_from_hc` |
| `quackback.yaml` | Medium | MinIO init container with `exclude_from_hc: true` |
| `discourse.yaml` | Complex | App + worker + PostgreSQL + Redis, SMTP |
| `lightrag-production.yaml` | Complex | App + Redis + Qdrant + Memgraph |
| `dify.yaml` | Expert | 10+ services, YAML anchors, SSRF proxy, sandbox, nginx, inline configs |

---

## Common Pitfalls

1. **Missing `# port:` header** — Coolify's Caddy proxy cannot auto-detect the port. Always specify it.
2. **Underscores in port identifiers** — `SERVICE_URL_MY_APP_8080` is parsed wrong. Use hyphens: `SERVICE_URL_MY-APP_8080`.
3. **`latest` tag on databases** — Breaking changes in major versions. Pin to `postgres:16-alpine`, not `postgres:latest`.
4. **Missing healthcheck** — Coolify cannot track readiness. `depends_on: condition: service_healthy` breaks without one.
5. **Forgetting `exclude_from_hc: true`** — Init containers that exit cause Coolify to report the service as unhealthy.
6. **Hardcoded secrets** — Never hardcode passwords. Use `$SERVICE_PASSWORD_*` for auto-generation.
7. **Logo path from wrong root** — Logo paths are resolved from the **repository root**, not the template folder. Use `svgs/myservice.svg`, not `../svgs/myservice.svg`.
8. **`coolify.proxyPorts` case sensitivity** — Must be camelCase: `coolify.proxyPorts`, not `coolify.proxyports`.
9. **`content:` bind mount without `source:`** — Even though the file is generated from inline content, `source: ./some-path` is required as a virtual path.
10. **YAML anchors with `<<:` merge** — Works in Coolify but test thoroughly. Complex anchors can cause parsing issues in some versions.
11. **Port conflict with `ports:` vs `SERVICE_FQDN`** — Use `SERVICE_FQDN_*` for proxy routing. Only use `ports:` for direct host exposure (bypasses proxy).
12. **`docker_compose_raw` is stored once** — After deployment, the compose is in Coolify's database. Template changes don't affect running services.
13. **Forgetting `PREMIUM.md` entry** — Premium templates must be cataloged so free users can see what's available and how to subscribe.
14. **Missing `restart: "no"` on init containers** — The default restart policy retries forever. One-shot containers need explicit `restart: "no"`.
15. **Using `version:` key** — Modern Docker Compose does not need a `version:` key. Omit it.

---

## AI Agent Instructions

When creating a new Coolify service template, follow this checklist:

1. **Research the service:** Read the official documentation to understand required services, ports, environment variables, and dependencies. Search the web for `"<service-name>" docker compose self-hosted` for community examples.

2. **Determine the architecture:** Identify what database(s), cache(s), and auxiliary services are needed. Check if the project has an official `docker-compose.yml` to use as reference.

3. **Determine the tier:** Free (default) for broadly useful community services. Premium for specialized enterprise stacks requiring significant support.

4. **Create the header metadata:** Include all required headers (`documentation`, `slogan`, `tags`, `port`, `author`, `repository`) and recommended headers (`category`, `logo`). If premium, add `# tier: premium`.

5. **Define services:**
   - Use official Docker images with specific version tags (not `latest` for databases)
   - Set up the FQDN variable on the primary service: `SERVICE_FQDN_<NAME>_<PORT>`
   - Use `SERVICE_USER_*` and `SERVICE_PASSWORD_*` for auto-generated credentials
   - Use distinct `SERVICE_PASSWORD_64_*` names for multiple long secrets
   - Use `${VAR:?}` for required user inputs and `${VAR:-default}` for optional ones
   - Add health checks to every long-running service
   - Use `depends_on` with `condition: service_healthy` for startup ordering
   - Use `exclude_from_hc: true` for init/migration containers
   - For database services, add `labels: coolify.database: "true"`
   - Use YAML anchors (`x-shared-env: &shared`) for shared environment blocks in complex templates

6. **Define volumes:** Use named volumes for all persistent data. Declare them at the bottom of the file.

7. **Add the logo:** Save an SVG to `svgs/<service-name>.svg`. Reference it in the header as `# logo: svgs/<service-name>.svg`.

8. **Validate:** Run `./scripts/validate-templates.sh templates/compose/<service-name>.yaml`.

9. **Test the template:** Deploy via Coolify's "Docker Compose Empty" option. Verify all services start, healthchecks pass, and the UI works.

10. **Update documentation:**
    - Add the new service to `README.md`
    - If premium: add entry to `PREMIUM.md` and SVG path to `.free-edition-ignore`

11. **Review with AGENTS.md:** Check `AGENTS.md` for project-specific patterns and gotchas.

# Premium Templates

These templates are available exclusively to [Corelix Cloud](https://corelix.io) subscribers. Each template is production-ready, fully configured, and maintained by the Corelix team with automated updates and priority support.

[Subscribe to Corelix Cloud](https://app.corelix.io/register) | [View pricing](https://corelix.io/pricing)

---

## What you get with Premium Templates

- **Production-ready configurations** — Tested, optimized, and ready to deploy with a single click
- **Automated updates** — Templates are kept up to date with the latest stable versions
- **Priority support** — Direct assistance from the Corelix team for deployment and configuration
- **Full template library** — Access to all current and future premium templates

---

## Available Premium Templates

### AI Orchestration

#### Paperclip

Open-source orchestration for zero-human AI companies. Manage a team of AI agents (Claude Code, OpenAI Codex, OpenClaw, Cursor) with org charts, budgets, governance, goal alignment, and a task manager UI. Multi-company support, cost tracking, scheduled heartbeats, and mobile-ready dashboard. 42k+ GitHub stars.

- **Category:** ai
- **Documentation:** [github.com/paperclipai/paperclip](https://github.com/paperclipai/paperclip)
- **Tags:** ai, agents, orchestration, llm, automation, multi-agent, company, governance
- **Services:** Paperclip server (Node.js + React UI) + PostgreSQL
- **Status:** Available now

---

*Templates below are planned for upcoming releases. This list will be updated as each template is published.*

### Integrated Stacks

#### Full Observability Stack (Grafana + Prometheus + Loki)

Complete monitoring pipeline: metrics collection (Prometheus + Node Exporter), log aggregation (Loki + Promtail), alerting (Alertmanager), and dashboards (Grafana) — all pre-wired with datasources and retention policies.

- **Category:** monitoring
- **Documentation:** [grafana.com/docs](https://grafana.com/docs/)
- **Tags:** monitoring, metrics, logs, grafana, prometheus, loki, alerting, observability
- **Why premium:** 6+ services with inline Prometheus scrape configs, Loki retention YAML, Alertmanager routing rules, and Grafana provisioning — all via `content:` bind mounts. Individual Grafana exists in Coolify but not the integrated observability stack.

#### DevOps Platform (Gitea + Woodpecker CI + Registry)

Self-hosted development platform: Git hosting (Gitea), CI/CD pipelines (Woodpecker), and Docker registry — a complete GitHub Actions alternative.

- **Category:** devops
- **Documentation:** [docs.gitea.com](https://docs.gitea.com/)
- **Tags:** git, ci-cd, registry, devops, gitea, woodpecker
- **Why premium:** 4+ services with SSH passthrough config, CI agent auto-registration via shared secrets, registry storage volumes, and shared PostgreSQL. Individual Gitea exists in Coolify but not the integrated CI/CD platform.

### Workflow & Orchestration

#### Temporal

Durable execution platform for workflow orchestration. Guarantees workflow completion despite failures, crashes, and timeouts. Multi-language SDK support (Go, Java, Python, TypeScript), built-in retry logic, and a web UI for monitoring.

- **Category:** devops
- **Documentation:** [docs.temporal.io](https://docs.temporal.io/)
- **Tags:** workflow, orchestration, durable-execution, microservices, temporal
- **Why premium:** 5+ services (server, web UI, admin tools, PostgreSQL, Elasticsearch) with complex namespace setup, database schema migrations, and dynamic config.

#### Apache Airflow

Data pipeline orchestration platform. DAG-based workflow scheduling, 1000+ operator plugins, task dependencies, and a web UI for monitoring — the industry standard for data engineering.

- **Category:** automation
- **Documentation:** [airflow.apache.org/docs](https://airflow.apache.org/docs/)
- **Tags:** data-pipeline, orchestration, etl, dag, scheduling, airflow
- **Why premium:** 5+ services (webserver, scheduler, worker, triggerer, PostgreSQL, Redis) with Celery executor, Fernet key generation, shared DAGs volume, and init-db migration container.

#### Dagster

Modern data orchestration platform. Software-defined assets, type-checked pipelines, built-in observability, and a rich UI — next-generation alternative to Airflow.

- **Category:** automation
- **Documentation:** [docs.dagster.io](https://docs.dagster.io/)
- **Tags:** data-pipeline, orchestration, assets, observability, dagster
- **Why premium:** 4+ services (webserver, daemon, PostgreSQL, user code server) with code location config, shared storage, and gRPC communication.

### AI & Search

#### Perplexica

Open-source AI-powered search engine (Perplexity alternative). Uses local LLMs via Ollama or SearXNG for web search, with focus modes (academic, writing, Wolfram Alpha, YouTube, Reddit).

- **Category:** ai
- **Documentation:** [github.com/ItzCraworzyy/Perplexica](https://github.com/ItzCraworzyy/Perplexica)
- **Tags:** ai, search, llm, perplexity, ollama, searxng
- **Why premium:** Multi-service stack with SearXNG integration, Ollama model management, and frontend/backend separation. Not in vanilla Coolify.

### DevOps & Infrastructure

#### Drone CI + Runner

Container-native CI/CD platform. Lightweight Docker-based pipelines with auto-scaling runners, secrets management, and native Git provider integration.

- **Category:** devops
- **Documentation:** [docs.drone.io](https://docs.drone.io/)
- **Tags:** ci-cd, drone, pipelines, containers, devops, docker
- **Why premium:** Multi-runner setup with Docker-in-Docker, agent auto-registration, shared secrets, and Gitea/GitHub/GitLab integration. Not in vanilla Coolify.

#### Harbor

Enterprise container registry with security scanning, RBAC, replication, and image signing. Goes far beyond a basic Docker registry with Trivy vulnerability scanning and audit logging.

- **Category:** devops
- **Documentation:** [goharbor.io/docs](https://goharbor.io/docs/)
- **Tags:** registry, containers, security, scanning, harbor, trivy
- **Why premium:** 8+ services (core, jobservice, registry, portal, database, Redis, Trivy, log) with complex inter-service authentication and shared secret keys. Vanilla Coolify has a basic `docker-registry` but not Harbor.

#### Sentry

Application performance monitoring and error tracking. Real-time crash reporting, performance tracing, session replay, and release tracking for production applications.

- **Category:** monitoring
- **Documentation:** [develop.sentry.dev/self-hosted](https://develop.sentry.dev/self-hosted/)
- **Tags:** error-tracking, apm, monitoring, debugging, sentry, performance
- **Why premium:** 15+ services (web, worker, cron, Kafka, Zookeeper, ClickHouse, PostgreSQL, Redis, Memcached, Snuba) — one of the most complex self-hosted stacks. Not in vanilla Coolify.

### Business & Operations

#### ERPNext

Full-featured open-source ERP: accounting, inventory, CRM, HR, manufacturing, project management, and more. The leading open-source alternative to SAP/Oracle ERP.

- **Category:** productivity
- **Documentation:** [docs.erpnext.com](https://docs.erpnext.com/)
- **Tags:** erp, accounting, inventory, crm, hr, manufacturing, erpnext
- **Why premium:** 5+ services (app, worker, scheduler, MariaDB, Redis) with Frappe framework, bench CLI, and complex site initialization. Not in vanilla Coolify.

#### Baserow

Open-source no-code database platform (Airtable alternative). Spreadsheet-like interface, API, plugins, real-time collaboration, and custom field types.

- **Category:** productivity
- **Documentation:** [baserow.io/docs](https://baserow.io/docs/)
- **Tags:** database, no-code, airtable, spreadsheet, collaboration, baserow
- **Why premium:** 4+ services (web-frontend, backend, Celery worker, PostgreSQL, Redis) with media storage, email config, and real-time WebSocket setup. Not in vanilla Coolify.

### Low-Code Platforms

#### ToolJet

Open-source low-code platform for building internal tools. Visual app builder with 50+ data source connectors, custom components, and role-based access — an alternative to Retool.

- **Category:** development
- **Documentation:** [docs.tooljet.com](https://docs.tooljet.com/)
- **Tags:** low-code, internal-tools, retool, app-builder, tooljet
- **Why premium:** 4+ services (server, PostgreSQL, Redis, workers) with complex SMTP, SSO, and datasource credential configuration. Not in vanilla Coolify.

### Identity & Security

#### Zitadel

Cloud-native identity management. OIDC/OAuth2/SAML provider with passkeys, MFA, branding, organizations, and SCIM provisioning — a modern alternative to Auth0/Keycloak. v4.13.1.

- **Category:** security
- **Documentation:** [zitadel.com/docs](https://zitadel.com/docs/)
- **Tags:** identity, oidc, oauth2, saml, passkeys, mfa, sso, scim, iam, zitadel, keycloak-alternative
- **Services:** nginx path router + ZITADEL API (Go) + ZITADEL Login UI (Next.js) + PostgreSQL
- **Why premium:** 4-service stack with path-based routing (nginx replaces Traefik for Coolify compatibility), shared bootstrap volume for PAT exchange between API and login UI, masterkey generation, and domain-aware external URL configuration.
- **Status:** Available now

---

## How to access Premium Templates

1. [Subscribe to Corelix Cloud](https://app.corelix.io/register)
2. In your Coolify dashboard, go to **Settings > Templates**
3. Add the premium template source (provided after subscription)
4. All premium templates appear in your **New Resource > Services** grid

Already subscribed? [Sign in to Corelix Cloud](https://app.corelix.io)

---

## Community Templates

All community (free) templates are available in the [templates/compose/](templates/compose/) folder and can be used with any Coolify installation. See the [README](README.md) for the full list.

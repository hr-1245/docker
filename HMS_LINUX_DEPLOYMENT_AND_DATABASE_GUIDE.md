# HMS Linux Deployment, Docker & PostgreSQL Replication Guide

Professional operations manual for deploying and maintaining the **HMS (Hospital Management System)** application stack on **Linux**, with **native PostgreSQL** (outside Docker) and optional **streaming replication**.

**Document basis:** Repository audit (`docker/`, `hms-api/`, `hms-web/`, `docs/`) plus operator-verified examples where noted. **No secrets** appear in this file—use `docker/.env` (gitignored) for credentials.

**Related documents:**

| Document | Purpose |
|----------|---------|
| `docs/HMS_DOCKER_LINUX_DEPLOYMENT_GUIDE.md` | Fresh Ubuntu install, phases 1–13 (2026-10-22 audit) |
| `docs/HMS_DOCKER_NEW_SYSTEM_SETUP.md` | New-system / migration setup |
| `docker/README-DOCKER.md` | Quick start |
| `docker/postgres/external/README.md` | Native DB + access roles |
| `docker/postgres/native-replication/README.md` | Replication concepts (Windows paths; Linux adapted below) |
| `database/master-replica/README.md` | Roles, replication model (Windows-oriented scripts) |

**On-server path (typical):** `/opt/HMS/docker` — same content as repository `docker/` when deployed.

---

## Table of contents

1. [Architecture overview](#1-architecture-overview)
2. [Audit summary (verified vs unverified)](#2-audit-summary-verified-vs-unverified)
3. [Linux directory structure](#3-linux-directory-structure)
4. [Remote access and terminal workflow](#4-remote-access-and-terminal-workflow)
5. [Docker deployment](#5-docker-deployment)
6. [HMS tenant model and configuration](#6-hms-tenant-model-and-configuration)
7. [PostgreSQL primary setup](#7-postgresql-primary-setup)
8. [PostgreSQL replica / standby](#8-postgresql-replica--standby)
9. [Backup and restore](#9-backup-and-restore)
10. [Complete deployment workflow for developers](#10-complete-deployment-workflow-for-developers)
11. [Troubleshooting](#11-troubleshooting)
12. [Daily maintenance quick reference](#12-daily-maintenance-quick-reference)
13. [Security precautions](#13-security-precautions)
14. [Final deployment checklist](#14-final-deployment-checklist)
15. [Appendix: Operator-verified production example](#15-appendix-operator-verified-production-example)

---

## 1. Architecture overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Linux host (e.g. SAFI-HOSPITAL-CMS)                             │
│                                                                  │
│  ┌──────────────────┐     ┌──────────────────┐                  │
│  │  docker-hms-web  │────▶│  docker-hms-api  │                  │
│  │  nginx + SPA     │     │  OFBiz / HMS API │                  │
│  │  host :8088→:80  │     │  host :8080→:80  │                  │
│  └──────────────────┘     └────────┬─────────┘                  │
│                                     │ JDBC                        │
│                                     │ host.docker.internal:5432   │
│                                     ▼                             │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Native PostgreSQL (NOT in docker-compose.yml)              │  │
│  │  Primary :5432 (read/write) — HMS connects HERE only       │  │
│  │  Optional standby :5433 (hot standby, read-only)             │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**Verified from `docker/docker-compose.yml`:**

| Component | Role |
|-----------|------|
| `hms-api` | Apache OFBiz HMS API (Java 17, Tomcat port 80 in container) |
| `hms-web` | React SPA built with Vite, served by nginx; proxies API via `HMS_WEB_API_UPSTREAM` |
| PostgreSQL | **External** — no `postgres` service in Compose |
| Volume `hms_api_runtime` | API runtime/logs under `/ofbiz/runtime` — **not** database files |

**Write path:** All HMS application writes go to the **primary** PostgreSQL instance (`DB_PORT`, default **5432**).  
**Read replica:** Optional; **not** used by `hms-api` for normal traffic in the default configuration.

**Automatic failover:** **Not** provided by this Compose stack. Document failover only if your team adds Patroni, repmgr, or manual runbooks (unverified in repo).

---

## 2. Audit summary (verified vs unverified)

### 2.1 Verified from repository

| Item | Source |
|------|--------|
| Two Compose services: `hms-api`, `hms-web` | `docker/docker-compose.yml` |
| DB via `OFBIZ_POSTGRES_*` / `DB_*` env vars | `docker-compose.yml`, `docker/.env.example` |
| `host.docker.internal` via `extra_hosts: host-gateway` on Linux | `docker-compose.yml` |
| Default ports `8080` (API), `8088` (web) | `.env.example` |
| Single-tenant id default `hms` | `HMS_TENANT_ID`, `VITE_HMS_TENANT_ID` |
| `HmsApiUtil.bindTenant` enforces configured tenant | `hms-api/.../HmsApiUtil.java` |
| Entrypoint skips seed/admin load (logs “Skipping…”) | `hms-api/docker/docker-entrypoint.sh` (see Linux deployment guide) |
| Access roles scripts (Bash) | `docker/postgres/external/hms-access-roles*.sh` |
| Replication user vars in `.env.example` | `POSTGRES_REPLICATION_*` |
| No Compose healthchecks defined | `docker-compose.yml` |

### 2.2 Verified on example production host (operator session, 2026-10-30)

*Treat as one deployment example—not guaranteed for every environment.*

| Item | Example value |
|------|----------------|
| Deployment path | `/opt/HMS/docker` |
| Container names | `docker-hms-api-1`, `docker-hms-web-1` |
| API DB env | `OFBIZ_POSTGRES_OFBIZ_DB=hms_db`, `OFBIZ_POSTGRES_HOST=host.docker.internal`, port `5432` |
| PostgreSQL | Version **18**, cluster `18-main` on **5432** |
| Optional standby | Cluster `18-standby` on **5433** (localhost), same-host streaming from primary |
| Database name in use | **`hms_db`** (repo default name is **`ofbiz_hms`** — use **your** `DB_NAME`) |

### 2.3 Unverified — confirm on your server

- Exact Git remotes/branches for `hms-api`, `hms-web`, and whether `docker/` lives in a monorepo or separate artifact
- PostgreSQL `listen_addresses`, `pg_hba.conf` CIDR for Docker bridge
- Whether `hms_ddl` ownership model is used vs `hms_app`-owned objects
- Physical replication slot name (`hms_replica_slot` in Windows docs vs temporary `pg_basebackup` slot on Linux)
- Firewall / cloud security groups
- Production admin login ids (e.g. `hms-admin`) and password policy
- Duplicate empty lines in `.env` (e.g. `OFBIZ_POSTGRES_OFBIZ_DB=` before a real value) — remove empty assignments

---

## 3. Linux directory structure

**Typical production layout** (sibling repos required for `docker compose build`):

```text
/opt/HMS/                          # or /opt/hms — team convention
├── docker/                        # ← run all compose commands here
│   ├── docker-compose.yml
│   ├── .env                       # secrets (gitignored) — never commit
│   ├── .env.example
│   ├── HMS_LINUX_DEPLOYMENT_AND_DATABASE_GUIDE.md   # this file
│   ├── README-DOCKER.md
│   ├── MIGRATION-NATIVE-POSTGRES.md
│   ├── postgres/
│   │   ├── external/              # DB grants, hotfix SQL, access roles
│   │   └── native-replication/    # replication concepts
│   ├── scripts/                   # verify-db-access-roles.sh, linux hotfixes, etc.
│   └── backups/                   # local backup copies (if used)
├── hms-api/                       # API build context (../hms-api)
└── hms-web/                       # Web build context (../hms-web)
```

| Path | Purpose |
|------|---------|
| `docker-compose.yml` | Defines `hms-api` and `hms-web` only |
| `.env` | Host ports, JDBC credentials, tenant id, replication passwords for scripts |
| `postgres/external/` | SQL and Bash for roles, optional finance/commission hotfixes |
| `scripts/` | Operational helpers (verify roles, subscription check, etc.) |
| `hms-api/Dockerfile` | Multi-stage Java 17 build, runtime user `ofbiz` |
| `hms-web/docker/Dockerfile` | Node 20 build → nginx; embeds `VITE_HMS_TENANT_ID` at **build** time |

---

## 4. Remote access and terminal workflow

### 4.1 Connect and open a shell

1. Connect to the Linux server using your organization’s method (e.g. **Remote Desktop** to a jump host, **SSH**, or VM console).
2. Open a **terminal** (GNOME Terminal, Konsole, or SSH session).
3. Navigate to the deployment directory:

```bash
cd /opt/HMS/docker
```

4. Confirm layout:

```bash
ls -la
test -f docker-compose.yml && test -d ../hms-api && test -d ../hms-web && echo "Layout OK"
```

### 4.2 Docker permission note

If `docker compose ps` fails with **permission denied** on the socket, either:

```bash
sudo docker compose ps
```

or add your user to the `docker` group (requires logout/login):

```bash
sudo usermod -aG docker "$USER"
```

---

## 5. Docker deployment

### 5.1 Prerequisites (host)

| Software | Required | Verify |
|----------|----------|--------|
| Docker Engine 24+ | Yes | `docker version` |
| Docker Compose v2 plugin | Yes | `docker compose version` |
| Git | Yes (if pulling code on server) | `git --version` |
| PostgreSQL client | Recommended | `psql --version` |

PostgreSQL **server** runs on the host (or another machine)—not in this Compose file.

### 5.2 Inspect current deployment

```bash
cd /opt/HMS/docker

docker compose ps
docker compose config          # validates .env + YAML; do not paste output publicly if it embeds secrets
docker images | grep -E 'hms-api|hms-web|docker-hms'
git -C ../hms-api status -sb   # if git used
git -C ../hms-web status -sb
```

### 5.3 Environment configuration

```bash
cp -n .env.example .env        # first time only; do not overwrite production .env blindly
chmod 600 .env
grep -E '^DB_NAME=|^DB_HOST=|^HMS_TENANT_ID=|^OFBIZ_POSTGRES_OFBIZ_DB=' .env
```

**Important:** Ensure **one** assignment per variable. Remove blank lines like `OFBIZ_POSTGRES_OFBIZ_DB=` that precede the real value.

Inside the running API container:

```bash
sudo docker exec docker-hms-api-1 printenv | grep -E 'OFBIZ_POSTGRES_OFBIZ_DB|OFBIZ_POSTGRES_HOST|OFBIZ_POSTGRES_PORT|HMS_TENANT_ID'
```

Compare with `docker/.env`.

### 5.4 Build and start commands

| Command | When to use | Effect |
|---------|-------------|--------|
| `docker compose build` | After code changes in Dockerfiles or app source | Builds images; does not start containers |
| `docker compose up -d` | Start or recreate containers from existing images | Detached start |
| `docker compose up -d --build` | Deploy new code | Build **then** start in one step |
| `docker compose restart hms-api` | Config/env change that does not need rebuild; quick API bounce | Restarts one service |
| `docker compose restart hms-web` | Web/nginx only | Restarts web |
| `docker compose logs -f hms-api` | Debugging | Follow API logs |
| `docker compose logs --tail 100 hms-web` | Debugging | Recent web logs |
| `docker compose down` | **Maintenance only** | Stops containers; **named volume `hms_api_runtime` retained** unless `-v` |
| `docker compose down -v` | **Avoid in production** | Removes named volumes — **data loss for API runtime volume** |

**Frontend changes** require **`docker compose build hms-web`** (tenant id and API mode are build args).

**Safe update sequence (typical):**

```bash
cd /opt/HMS/docker
# git pull on approved branches (hms-api, hms-web, docker/) per your release process
docker compose build hms-api hms-web
docker compose up -d
docker compose ps
```

### 5.5 Verify API and web

```bash
curl -s -o /dev/null -w "API HTTP %{http_code}\n" http://127.0.0.1:8080/
curl -s -o /dev/null -w "Web HTTP %{http_code}\n" http://127.0.0.1:8088/
```

Login check (replace password interactively; do not log secrets):

```bash
curl -sS -X POST http://127.0.0.1:8080/hms/control/login \
  -H "Content-Type: application/json" \
  -d '{"USERNAME":"<your-admin-login>","PASSWORD":"<password>","userTenantId":"hms"}'
```

Expect HTTP **200** and JSON with tokens when credentials are valid.

---

## 6. HMS tenant model and configuration

### 6.1 What a “tenant” is in this HMS deployment

- **Logical tenant id** (default **`hms`**) — not a separate PostgreSQL database in the default Docker `.env`.
- Clients send **`userTenantId`** (login and API payloads).
- API reads **`HMS_TENANT_ID`** from the environment and **`HmsApiUtil.bindTenant`** rejects any other tenant id.
- Delegator target: **`default#hms`** when configured; may fall back to base delegator if tenant delegator is absent (see `HmsApiUtil.java`).

### 6.2 Configuration files and variables

| Location | Variable | Purpose |
|----------|----------|---------|
| `docker/.env` | `HMS_TENANT_ID` | Runtime API tenant (default `hms`) |
| `docker-compose.yml` build args | `VITE_HMS_TENANT_ID` | Baked into web SPA at **build** time |
| Login UI | User enters tenant | Must match `HMS_TENANT_ID` |

### 6.3 Creating a “new tenant”

**Not documented as a single command in this repository.** Default deployment is **single tenant / single database**.

To add another tenant in the OFBiz multi-tenant sense would require **verified team runbooks** beyond this repo (entity delegator config, tenant database or partition, seed data). **Do not invent SQL or CLI** without DBA/architect approval.

**For the default `hms` tenant:**

1. Restore or maintain HMS data in the application database (`DB_NAME` / `OFBIZ_POSTGRES_OFBIZ_DB`).
2. Ensure **`UserLogin`** rows exist (table **`user_login`**, schema **`public`**) — e.g. dashboard admin login id used at your site.
3. Set `HMS_TENANT_ID=hms` and rebuild web if you change tenant id.
4. Log in with matching **`userTenantId`**.

### 6.4 Verify tenant

```bash
# API env
sudo docker exec docker-hms-api-1 printenv HMS_TENANT_ID

# DB connectivity (use your DB name from .env)
sudo -u postgres psql -d hms_db -c "SELECT COUNT(*) FROM user_login;"
```

Login failure with tenant message → check API logs:

```bash
sudo docker compose logs hms-api --tail 80 | grep -i tenant
```

---

## 7. PostgreSQL primary setup

### 7.1 Installation (Ubuntu — reference)

Repository documents PostgreSQL **16+** (`docker/postgres/external/README.md`); **17/18** observed in production. Install per your LTS (example):

```bash
sudo apt update
sudo apt install -y postgresql postgresql-client
psql --version
sudo systemctl status postgresql
```

**Cluster naming (Ubuntu/Debian):** e.g. `postgresql@18-main` — use `systemctl list-units 'postgresql@*'`.

### 7.2 Database and roles (from repo templates)

Defaults in `.env.example`:

| Role | Typical use |
|------|-------------|
| `hms_app` | HMS API JDBC user |
| `postgres` | Admin for backups/grants (`NATIVE_POSTGRES_ADMIN_*`) |
| `replicator` | Physical replication only |
| `hms_db_full`, `hms_db_write`, `hms_db_read` | Optional scoped clients |

New install SQL pattern (adjust names/passwords — see `docker/postgres/external/README.md`):

```sql
-- Run as superuser; skip if database already exists
CREATE USER hms_app WITH PASSWORD 'set-strong-password';
CREATE DATABASE ofbiz_hms OWNER hms_app;
GRANT CONNECT ON DATABASE ofbiz_hms TO hms_app;
\c ofbiz_hms
GRANT USAGE ON SCHEMA public TO hms_app;
-- Additional grants per team model (hms_ddl vs hms_app)
```

**Production example database name:** `hms_db` (confirm with `grep DB_NAME docker/.env`).

### 7.3 How HMS API connects

1. Container env: `OFBIZ_POSTGRES_HOST`, `OFBIZ_POSTGRES_PORT`, `OFBIZ_POSTGRES_OFBIZ_DB`, `OFBIZ_POSTGRES_OFBIZ_USER`, `OFBIZ_POSTGRES_OFBIZ_PASSWORD`.
2. Entrypoint renders **`config/entityengine.xml`** from template using those variables.
3. Datasource **`localpostgres_hms`**, schema **`public`** (`entityengine.xml`).

### 7.4 Docker → host connectivity

| Setting | Linux typical |
|---------|----------------|
| `DB_HOST` / `OFBIZ_POSTGRES_HOST` | `host.docker.internal` (Compose adds `host-gateway`) |
| `DB_PORT` | `5432` (primary) |

**On the host:**

- `listen_addresses` must include an address reachable from Docker (e.g. `localhost`, host IP, or `*` — tighten per security policy).
- **`pg_hba.conf`**: allow **`hms_app`** from Docker bridge (e.g. `172.17.0.0/16` or specific IP) with `scram-sha-256`.

Verify from host:

```bash
pg_isready -h 127.0.0.1 -p 5432
sudo ss -tlnp | grep 5432
```

Verify from container:

```bash
sudo docker exec docker-hms-api-1 getent hosts host.docker.internal
# JDBC test: watch hms-api logs after restart
sudo docker compose restart hms-api
sudo docker compose logs hms-api --tail 50
```

### 7.5 Connection test (host)

```bash
export PGPASSWORD='use-app-password-from-env'
psql -h 127.0.0.1 -p 5432 -U hms_app -d hms_db -c "SELECT 1 AS ok;"
unset PGPASSWORD
```

---

## 8. PostgreSQL replica / standby

### 8.1 Roles

| Instance | Port (example) | Writable | HMS API |
|----------|----------------|----------|---------|
| **Primary** | 5432 | Yes | **Connects here** |
| **Standby** | 5433 (optional) | No (hot standby) | **Do not** point `DB_HOST` here for API |

Purpose: redundancy, read-only queries, DR **without** automatic promotion in default stack.

### 8.2 Primary settings (streaming replication)

Required on **primary** (verify with SQL):

```sql
SHOW wal_level;              -- expect replica
SHOW max_wal_senders;
SHOW max_replication_slots;
```

Example `postgresql.conf` on primary (values must match your policy):

```ini
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
```

**Replication user** (from `.env.example`):

```sql
-- Verify only
\du replicator
```

**`pg_hba.conf` on primary** (examples):

```text
host  replication  replicator  127.0.0.1/32   scram-sha-256
host  replication  replicator  <standby-ip>/32  scram-sha-256
```

Reload after change: `sudo systemctl reload postgresql@18-main` (adjust cluster name).

### 8.3 Same-host standby (Ubuntu — verified pattern)

**Do not** replace primary data directory `main` with `pg_basebackup`. Use a **second cluster**:

```bash
# Primary must be running
sudo pg_createcluster 18 standby --port=5433
sudo systemctl stop postgresql@18-standby

# Empty data dir completely, then base backup
sudo rm -rf /var/lib/postgresql/18/standby
sudo install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/18/standby

sudo -u postgres pg_basebackup \
  -h 127.0.0.1 -p 5432 -U replicator \
  -D /var/lib/postgresql/18/standby \
  -P -v -R -X stream

# Standby GUCs must be >= primary (example from ops)
echo 'max_locks_per_transaction = 512' | sudo tee /etc/postgresql/18/standby/conf.d/recovery-gucs.conf

sudo systemctl start postgresql@18-standby
sudo systemctl enable postgresql@18-standby
```

`-R` creates **`standby.signal`** and **`primary_conninfo`** in the standby data directory.

### 8.4 Monitoring replication

**On primary (`5432`):**

```sql
SELECT application_name, client_addr, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

**On standby (`5433`):**

```sql
SELECT pg_is_in_recovery();   -- expect t
SELECT status, conninfo FROM pg_stat_wal_receiver;
```

**Shell:**

```bash
sudo ss -tlnp | grep -E '5432|5433'
sudo systemctl status postgresql@18-main postgresql@18-standby
```

### 8.5 Failover

**Not automated** in HMS Docker stack. If primary fails:

- Standby does **not** promote itself.
- Recovery requires **manual** promotion or restore from backup per DBA runbook (out of scope unless your team documents it).

### 8.6 Replication troubleshooting

| Symptom | Check | Action |
|---------|-------|--------|
| `pg_basebackup` timeout to public IP | Firewall / SG | Use LAN IP; open 5432 from standby only |
| `connection refused` on `172.17.0.1` | Wrong target | Use primary IP or `127.0.0.1` for same-host |
| Standby fails: `insufficient parameter settings` | GUC mismatch | Match `max_locks_per_transaction` etc. on standby |
| Empty `pg_stat_replication` | Standby down / wrong `primary_conninfo` | Start standby; check logs |
| Accidentally moved primary `main` | API down | Restore `main` from backup; never use `main` as basebackup target |

---

## 9. Backup and restore

### 9.1 Before every deployment

Take a logical backup of the **primary** application database (use **your** `DB_NAME`):

```bash
BACKUP_DIR="$HOME/hms-backups"
mkdir -p "$BACKUP_DIR"
export PGPASSWORD='admin-password-from-secure-store'
pg_dump -h 127.0.0.1 -p 5432 -U postgres -Fc \
  -f "$BACKUP_DIR/hms_db_$(date +%Y%m%d_%H%M).dump" hms_db
unset PGPASSWORD
ls -lh "$BACKUP_DIR" | tail -5
```

### 9.2 Plain SQL backup

```bash
pg_dump -h 127.0.0.1 -p 5432 -U postgres -f "$BACKUP_DIR/hms_db_$(date +%Y%m%d).sql" hms_db
```

### 9.3 Restore (non-production test first)

**Warning:** Restoring over production destroys current data. Always backup first.

Custom format:

```bash
createdb -h 127.0.0.1 -U postgres hms_db_restore_test
pg_restore -h 127.0.0.1 -U postgres -d hms_db_restore_test --no-owner --role=hms_app \
  "$BACKUP_DIR/hms_db_YYYYMMDD.dump"
```

### 9.4 Verify backup

```bash
pg_restore -l "$BACKUP_DIR/hms_db_YYYYMMDD.dump" | head
```

### 9.5 Configuration backups

Also backup (no secrets in git):

- `docker/.env` (secure store)
- `/etc/postgresql/<ver>/main/postgresql.conf`, `pg_hba.conf`
- Standby cluster config if used

### 9.6 Scheduled backups (example cron — adjust paths)

```cron
0 2 * * * postgres pg_dump -h 127.0.0.1 -p 5432 -Fc -f /var/backups/hms/hms_db_$(date +\%Y\%m\%d).dump hms_db
```

**Never** delete old backups without retention policy approval.

---

## 10. Complete deployment workflow for developers

1. Connect to Linux (RDP/SSH).
2. Open terminal → `cd /opt/HMS/docker`.
3. `sudo docker compose ps` — note running state.
4. `git -C ../hms-api status` / `git -C ../hms-web status` — confirm branch.
5. **Backup database** (Section 9).
6. Review `docker/.env` (DB_NAME, hosts, tenant, ports); fix duplicate empty keys.
7. Pull **approved** code (merge via PR policy — e.g. Azure DevOps may block direct push to `master`).
8. `docker compose build hms-api hms-web` (or `up -d --build`).
9. `docker compose up -d`.
10. `docker compose ps`.
11. `docker compose logs hms-api --tail 80`.
12. `docker compose logs hms-web --tail 40`.
13. `psql` / `pg_isready` — DB up.
14. `pg_stat_replication` / `pg_is_in_recovery` — replication healthy if used.
15. Login test with correct **`userTenantId`**.
16. Smoke test critical HMS flows (team checklist).
17. Record deployment in change log.

---

## 11. Troubleshooting

Format: **Problem → Diagnostic → Cause → Safe fix**

| Problem | Diagnostic | Cause | Safe fix |
|---------|------------|-------|----------|
| Container not starting | `docker compose ps`; `docker compose logs <svc>` | Bad env, port bind, crash loop | Fix `.env`; free port; read stack trace |
| Build failure | `docker compose build 2>&1` | Missing context dir, network | Ensure `../hms-api`, `../hms-web` exist |
| API cannot connect to PG | `docker compose logs hms-api` | Wrong host, auth, pg_hba | Use `host.docker.internal`; fix `pg_hba`; align passwords |
| Connection refused :5432 | `ss -tlnp \| grep 5432`; `systemctl status postgresql@*` | PG down / wrong port | Start primary cluster |
| Wrong database | `printenv OFBIZ_POSTGRES_OFBIZ_DB` in container | `.env` typo / duplicate empty key | Fix `.env`; `up -d hms-api` |
| `user_login` not found | `SELECT current_database();` `\dt public.user_login` | Connected to wrong DB | Use `hms_db` or your `DB_NAME` |
| Tenant rejected | API logs `bindTenant` | Login tenant ≠ `HMS_TENANT_ID` | Align tenant in UI and `.env`; rebuild web if needed |
| Login 401 | curl login test | Bad password / disabled user | Reset password via approved runbook; check `enabled` in `user_login` |
| Web 502 | `docker compose logs hms-web` | API down | Fix `hms-api` first |
| Replication stopped | `pg_stat_replication`; standby logs | Standby down, auth, GUC | Restart standby; fix `pg_hba`; match GUCs |
| Replica lag | `lag_bytes` query | Load, network | Monitor; investigate long transactions on primary |
| `docker compose down -v` accident | Volume missing | Operator error | Restore API runtime from backup; DB unaffected if PG external |

---

## 12. Daily maintenance quick reference

```bash
# Docker
cd /opt/HMS/docker
sudo docker compose ps
sudo docker compose logs hms-api --tail 30
sudo docker compose restart hms-api    # only when needed

# PostgreSQL primary
sudo systemctl status postgresql@18-main
pg_isready -h 127.0.0.1 -p 5432
sudo -u postgres psql -p 5432 -c "SELECT state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication;"

# Standby (if configured)
sudo systemctl status postgresql@18-standby
sudo -u postgres psql -p 5433 -c "SELECT pg_is_in_recovery();"

# Disk
df -h
docker system df
```

---

## 13. Security precautions

- Never commit `docker/.env`; `chmod 600 .env`.
- Do not expose PostgreSQL **5432** to the public internet.
- Do not publish passwords in docs, tickets, or chat.
- Do not run `docker compose down -v` on production.
- Do not use **`replicator`** for HMS application JDBC.
- Prefer SCRAM in `pg_hba.conf`.
- Rotate credentials if exposed.
- Apply OS and PostgreSQL security updates per policy.

---

## 14. Final deployment checklist

- [ ] `/opt/HMS/docker` layout with sibling `hms-api`, `hms-web`
- [ ] `docker/.env` complete, no duplicate empty keys, mode `600`
- [ ] Container env matches `.env` (`printenv` check)
- [ ] PostgreSQL primary running on **5432**
- [ ] `hms_app` connects to **`DB_NAME`** database
- [ ] `docker compose up -d` — both services **Up**
- [ ] Web :8088 and API :8080 respond
- [ ] Login works with configured tenant (**`hms`** default)
- [ ] Backup taken and verified
- [ ] Standby :5433 streaming (if deployed)
- [ ] Firewall reviewed
- [ ] No secrets in git

---

## 15. Appendix: Operator-verified production example

**Host:** SAFI-HOSPITAL-CMS (example, 2026-10-30)

| Item | Value |
|------|--------|
| Compose path | `/opt/HMS/docker` |
| DB name | `hms_db` |
| API → DB | `host.docker.internal:5432` |
| PG clusters | `18-main` (5432), `18-standby` (5433) |
| Dashboard admin login id | `hms-admin` (in `user_login`; confirm before password ops) |
| Replication local | `127.0.0.1` / `replicator` in `pg_hba.conf` |

This appendix is **illustrative**. Always run discovery commands on **your** host before changes.

---

*Document version: 2026-11-03 — repository audit + Linux replication operator notes. File location in repo: `docker/HMS_LINUX_DEPLOYMENT_AND_DATABASE_GUIDE.md`. Deploy copy to `/opt/HMS/docker/` on the server with your release process.*

# HMS Docker (application stack)



Stack: **hms-api** (OFBiz) + **hms-web** (nginx + SPA), connecting to **external/native PostgreSQL**.



PostgreSQL runs **outside Docker**. See `postgres/external/README.md` for database setup and access roles.



## Prerequisites



- Docker Engine 24+ and Docker Compose v2

- PostgreSQL 16+ installed and running **outside Docker**

- HMS database (`ofbiz_hms` or your `DB_NAME`) and application user (`hms_app` or your `DB_USER`)

- Enough RAM for OFBiz (~2 GB for `hms-api`)



## Quick start



```bash

cd docker

cp .env.example .env

# Set DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, and access-role passwords.



docker compose build

docker compose up -d

```



- Web UI: http://localhost:8088 (`HMS_WEB_PORT`)

- API: http://localhost:8080 (`HMS_API_PORT`)



### Reach host PostgreSQL from Docker



| Platform | Typical `DB_HOST` |

|----------|-------------------|

| Docker Desktop (Windows/macOS) | `host.docker.internal` |

| Linux | Host IP or `host.docker.internal` (compose adds `host-gateway`) |



Ensure PostgreSQL `listen_addresses` / `pg_hba.conf` and firewall allow the Docker bridge to connect.



## Database access roles



Three login roles on the **same** HMS database (not separate databases). HMS uses `DB_USER` / `OFBIZ_POSTGRES_OFBIZ_USER`; the three roles are for permission-scoped clients.



| Role | SELECT | INSERT | UPDATE | DELETE |

|------|--------|--------|--------|--------|

| Full (`POSTGRES_HMS_FULL_ACCESS_USER`) | yes | yes | yes | yes |

| Write (`POSTGRES_HMS_WRITE_ACCESS_USER`) | no | yes | yes | yes |

| Read (`POSTGRES_HMS_READ_ONLY_USER`) | yes | no | no | no |



Apply on the external server:



```bash

bash postgres/external/hms-access-roles.sh

bash scripts/verify-db-access-roles.sh

```



## Entity Engine / environment variables



`hms-api` renders `config/entityengine.xml` from `OFBIZ_POSTGRES_*` (see `hms-api/docker/docker-entrypoint.sh`). Supported aliases:



| Generic | Maps to |

|---------|---------|

| `DB_HOST` | `OFBIZ_POSTGRES_HOST` |

| `DB_PORT` | `OFBIZ_POSTGRES_PORT` |

| `DB_NAME` | `OFBIZ_POSTGRES_OFBIZ_DB` |

| `DB_USER` | `OFBIZ_POSTGRES_OFBIZ_USER` |

| `DB_PASSWORD` | `OFBIZ_POSTGRES_OFBIZ_PASSWORD` |



## Data safety



- Do **not** run `docker compose down -v` if volumes contain data you need.

- Do **not** drop HMS databases or tables as part of deployment.

- Back up with `pg_dump` before major changes.



## Subscription expiry



See `hms-api/.env.example` — `SUBSCRIPTION_DAYS`, `SUBSCRIPTION_START_DATE`. Test: `./scripts/verify-subscription.sh`



## Mail / SMTP (doctor credential emails)



Compose only injects variables listed under `hms-api.environment`. Set these in `docker/.env` (cPanel SSL/TLS example):



```bash

HMS_WEB_LOGIN_URL=https://portal.example.com

HMS_MAIL_FROM=info@example.com

HMS_MAIL_ENABLED=Y

HMS_SMTP_HOST=mail.example.com

HMS_SMTP_PORT=465

HMS_SMTP_USER=info@example.com

HMS_SMTP_PASSWORD=your_mailbox_password

HMS_SMTP_STARTTLS=false

```



- Port **465** = implicit SSL (`HMS_SMTP_STARTTLS=false`). Port **587** = STARTTLS (`true`).

- `HMS_MAIL_FROM` should match the mailbox (`HMS_SMTP_USER`), or the provider may reject the message.

- After changing mail env: `docker compose up -d --force-recreate hms-api`



## Edge nginx-proxy 413 / 504



On SAFI-HOSPITAL-CMS, TLS terminates in the Docker container **`nginx-proxy`** (systemd `nginx.service` is not used). `hms-web` already allows 32m; the edge proxy still needs:



```bash

docker cp nginx-proxy/portal-extra.conf nginx-proxy:/etc/nginx/conf.d/portal-extra.conf

docker exec nginx-proxy nginx -t && docker exec nginx-proxy nginx -s reload

```



That sets `client_max_body_size 32m` (fixes photo **413**) and longer `proxy_read_timeout` (avoids **504** while the API waits on SMTP). Rebuild API after mail timeout changes:



```bash

docker compose up -d --build --force-recreate hms-api

docker exec docker-hms-api-1 printenv | grep HMS_MAIL

docker exec docker-hms-api-1 printenv | grep HMS_SMTP

```



## Environment reference



- `docker/.env.example` — Docker stack + external DB

- `hms-api/.env.example` — OFBiz/HMS when running API outside Docker

- `docker/host-nginx-portal.snippet.conf` — host TLS nginx body size for uploads


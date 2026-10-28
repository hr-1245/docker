# External (native) PostgreSQL for HMS

HMS uses **one database** on a PostgreSQL server **outside Docker**. The application (`hms-api`) connects via environment variables (see `docker/.env.example`).

## Administrator checklist

1. Install PostgreSQL 16+ on the host (Windows/Linux).
2. Create the HMS database and application login (if not already present from a prior install).
3. Restore or keep existing HMS data — **do not drop** production databases.
4. Apply the three access roles (full / write / read-only).
5. Configure `docker/.env` with `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`.
6. Start HMS: `docker compose up -d` from the `docker/` directory.

## Create database and app user (new installs only)

Run as a PostgreSQL superuser (adjust names to match `.env`):

```sql
CREATE USER hms_app WITH PASSWORD 'your_app_password';
CREATE DATABASE ofbiz_hms OWNER hms_app;
GRANT ALL PRIVILEGES ON DATABASE ofbiz_hms TO hms_app;
\c ofbiz_hms
GRANT ALL ON SCHEMA public TO hms_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO hms_app;
```

Skip this if the database and `hms_app` already exist.

## Apply access roles (full / write / read-only)

Set in `docker/.env`:

- `POSTGRES_HMS_FULL_ACCESS_*`
- `POSTGRES_HMS_WRITE_ACCESS_*`
- `POSTGRES_HMS_READ_ONLY_*`
- `POSTGRES_ADMIN_USER` / `POSTGRES_ADMIN_PASSWORD` (or `NATIVE_POSTGRES_*`) for the superuser used to run grants

From `docker/` (requires `psql` on the machine that can reach PostgreSQL):

```bash
bash postgres/external/hms-access-roles.sh
bash scripts/verify-db-access-roles.sh
```

Roles and grants are stored in PostgreSQL catalog data — they survive PostgreSQL and HMS container restarts.

## Docker Desktop → host PostgreSQL

Use `DB_HOST=host.docker.internal` and `DB_PORT=<native PostgreSQL port>` in `docker/.env`. Ensure `pg_hba.conf` allows connections from Docker bridge addresses and the Windows/Linux firewall permits the port.

## Historical note (local machines only, non-active)

If this host was migrated from an older in-Docker PostgreSQL setup, leftover Docker volumes (for example `docker_pg_primary_data` / `docker_pg_replica_data`) may still exist. They are **not** part of the current HMS compose stack and are **not** removed by this project. Copying/zipping this `docker/` folder to a new machine does **not** deploy those volumes or any legacy PostgreSQL service.

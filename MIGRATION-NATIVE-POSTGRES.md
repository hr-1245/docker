# Migration: in-Docker PostgreSQL → native PostgreSQL (completed)

This project now uses **native/external PostgreSQL only**. The former in-Docker primary/replica stack and its compose/env configuration have been removed from the repository.

## Current deployment

- HMS connects via `DB_HOST` / `OFBIZ_POSTGRES_HOST` (typically `host.docker.internal`) and `DB_PORT` / `OFBIZ_POSTGRES_PORT` (`5432`).
- Apply access roles: `bash postgres/external/hms-access-roles.sh`
- Verify roles: `bash scripts/verify-db-access-roles.sh`

## Historical note — host-only rollback (non-active)

**This section is informational only.** The removed in-Docker PostgreSQL stack cannot be started from this repository.

On a machine that already completed migration, you may still find local artifacts such as:

- Stopped containers that used to be named like `docker-postgres-primary-1` / `docker-postgres-replica-1`
- Docker volumes `docker_pg_primary_data` / `docker_pg_replica_data`
- Native database `ofbiz_hms_stale_20261001`

None of these are created or managed by the current `docker-compose.yml`. Deleting them is a manual host decision.

## Backup reference

A migration backup may exist under `docker/backups/` (gitignored). Use `pg_dump` / `pg_restore` against native PostgreSQL for ongoing backups.

# Native PostgreSQL streaming replication (Windows)

HMS uses **one write primary** on the host. An optional **read-only standby** replicates the same `ofbiz_hms` database for redundancy and future reporting. **HMS API always connects to the primary only** (`host.docker.internal:5432`).

## Architecture

```
hms-api (Docker) ──► Primary PostgreSQL 17 :5432 (read/write, ofbiz_hms)
                           │
                           │ streaming replication (WAL)
                           ▼
                     Standby PostgreSQL 17 :5433 (hot standby, read-only)
```

- **Application user:** `hms_app` → primary only (Entity Engine).
- **Access roles:** `hms_db_full`, `hms_db_write`, `hms_db_read` → logical permissions on the database (unchanged by replication).
- **Replication user:** `replicator` → physical replication only (not used by HMS).

## Paths (this machine)

| Instance | Port | Data directory |
|----------|------|----------------|
| Primary | 5432 | `C:\Program Files\PostgreSQL\17\data` |
| Standby | 5433 | `C:\PostgreSQL\17\data_replica` |

Primary Windows service: `postgresql-x64-17` (`NT AUTHORITY\NetworkService`).

Standby may run via `pg_ctl` until an administrator registers `postgresql-x64-17-replica` (see `docker/scripts/register-postgres-replica-service.ps1`).

## Credentials

Set in **gitignored** `docker/.env` only (never commit):

- `POSTGRES_REPLICATION_USER=replicator`
- `POSTGRES_REPLICATION_PASSWORD=[MASKED]`

Replication password is also referenced in standby `postgresql.auto.conf` on the host (restricted by file ACLs).

## Primary configuration

- `wal_level=replica`, `max_wal_senders`, `hot_standby` — verified compatible on primary.
- Physical slot: `hms_replica_slot`.
- **pg_hba.conf:** existing local `replication` rules for `127.0.0.1/32` and `::1/128` (no project file edit required). Config backup: `docker/backups/pg-primary-config-20261002/`.

## Operations

**Check replication (primary):**

```sql
SELECT * FROM pg_stat_replication;
SELECT * FROM pg_replication_slots WHERE slot_name = 'hms_replica_slot';
```

**Check standby:**

```sql
SELECT pg_is_in_recovery();  -- expect true
SELECT * FROM pg_stat_wal_receiver;
```

**Start standby (if not registered as a service):**

```powershell
& "C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe" start -D "C:\PostgreSQL\17\data_replica" -w -l "C:\PostgreSQL\17\data_replica\postgresql.log"
```

**Stop standby only (primary and HMS unaffected):**

```powershell
& "C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe" stop -D "C:\PostgreSQL\17\data_replica" -m fast -w
```

## Out of scope

- HMS read/write split, automatic failover, Docker PostgreSQL, and application code changes.

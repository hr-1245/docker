#!/usr/bin/env bash
# Verify HMS table-level privileges for the three access roles on external PostgreSQL.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if [[ ! -f .env ]]; then
  echo "Missing docker/.env — copy from .env.example" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

DB="${OFBIZ_POSTGRES_OFBIZ_DB:-${DB_NAME:-ofbiz_hms}}"
FULL="${POSTGRES_HMS_FULL_ACCESS_USER:-hms_db_full}"
WRITE="${POSTGRES_HMS_WRITE_ACCESS_USER:-hms_db_write}"
READ="${POSTGRES_HMS_READ_ONLY_USER:-hms_db_read}"

export PGHOST="${PGHOST:-${OFBIZ_POSTGRES_HOST:-${DB_HOST:-localhost}}}"
export PGPORT="${PGPORT:-${OFBIZ_POSTGRES_PORT:-${DB_PORT:-5432}}}"
ADMIN_USER="${POSTGRES_ADMIN_USER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-${POSTGRES_ADMIN_PASSWORD:-${NATIVE_POSTGRES_ADMIN_PASSWORD:-}}}"

SAMPLE_TABLE="$(psql -U "${ADMIN_USER}" -d "${DB}" -tAc \
  "SELECT quote_ident(tablename) FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename LIMIT 1" | tr -d '[:space:]')"

if [[ -z "${SAMPLE_TABLE}" ]]; then
  echo "No public tables in ${DB}; privilege matrix skipped." >&2
  exit 0
fi

echo "Host: ${PGHOST}:${PGPORT}  Database: ${DB}  Sample table: ${SAMPLE_TABLE}"

check_priv() {
  local role="$1"
  local priv="$2"
  psql -U "${ADMIN_USER}" -d "${DB}" -tAc \
    "SELECT has_table_privilege('${role}', '${SAMPLE_TABLE}', '${priv}')"
}

echo "--- has_table_privilege ---"
for role in "${FULL}" "${WRITE}" "${READ}"; do
  echo "Role: ${role}"
  for priv in SELECT INSERT UPDATE DELETE; do
    echo "  ${priv}: $(check_priv "${role}" "${priv}")"
  done
done

run_as() {
  local user="$1"
  local pass="$2"
  local sql="$3"
  PGPASSWORD="${pass}" psql -U "${user}" -d "${DB}" -v ON_ERROR_STOP=1 -c "${sql}" 2>&1 || true
}

if [[ -n "${POSTGRES_HMS_READ_ONLY_PASSWORD:-}" ]]; then
  echo "--- read-only: SELECT (expect OK) ---"
  run_as "${READ}" "${POSTGRES_HMS_READ_ONLY_PASSWORD}" "SELECT 1 FROM ${SAMPLE_TABLE} LIMIT 1;"
fi

if [[ -n "${POSTGRES_HMS_WRITE_ACCESS_PASSWORD:-}" ]]; then
  echo "--- write: SELECT (expect permission denied) ---"
  run_as "${WRITE}" "${POSTGRES_HMS_WRITE_ACCESS_PASSWORD}" "SELECT 1 FROM ${SAMPLE_TABLE} LIMIT 1;"
fi

if [[ -n "${POSTGRES_HMS_FULL_ACCESS_PASSWORD:-}" ]]; then
  echo "--- full: SELECT (expect OK) ---"
  run_as "${FULL}" "${POSTGRES_HMS_FULL_ACCESS_PASSWORD}" "SELECT 1 FROM ${SAMPLE_TABLE} LIMIT 1;"
fi

echo "--- HMS API (docker compose) ---"
docker compose ps hms-api --status running 2>/dev/null || echo "(start with: docker compose up -d hms-api)"

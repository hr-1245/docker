#!/bin/bash
# Apply HMS table-level access roles on an external/native PostgreSQL server (idempotent).
# Run on the DB host with psql client. Loads credentials from docker/.env by default.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${HMS_DOCKER_ENV:-${ROOT}/.env}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

export PGHOST="${PGHOST:-${NATIVE_POSTGRES_HOST:-${DB_HOST:-${OFBIZ_POSTGRES_HOST:-localhost}}}}"
export PGPORT="${PGPORT:-${NATIVE_POSTGRES_PORT:-${DB_PORT:-${OFBIZ_POSTGRES_PORT:-5432}}}}"
export PGUSER="${PGUSER:-${NATIVE_POSTGRES_ADMIN_USER:-${POSTGRES_ADMIN_USER:-postgres}}}"
export PGPASSWORD="${PGPASSWORD:-${NATIVE_POSTGRES_ADMIN_PASSWORD:-${POSTGRES_ADMIN_PASSWORD:-}}}"

export POSTGRES_USER="${POSTGRES_USER:-${PGUSER}}"

exec "${ROOT}/postgres/external/hms-access-roles-apply.sh"

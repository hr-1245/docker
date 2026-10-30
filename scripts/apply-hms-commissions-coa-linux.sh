#!/usr/bin/env bash
# Load OFBiz/HMS GL accounts on the HMS tenant DB and set COMMISSIONS_PAYABLE default.
# Fixes: "COMMISSIONS_PAYABLE GL account is not configured for organization Company"
#
# Run on the Linux host from the docker compose directory:
#   cd /opt/HMS/docker
#   chmod +x scripts/apply-hms-commissions-coa-linux.sh
#   ./scripts/apply-hms-commissions-coa-linux.sh
#
# Requires: running hms-api container, psql client, postgres superuser (or role that can read/write hms_db).
# Docker: auto-uses `sudo docker compose` when plain `docker` is root-only (common on Linux servers).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/docker-compose.sh
source "$SCRIPT_DIR/lib/docker-compose.sh"

COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$COMPOSE_DIR/.." && pwd)"
MIGRATION_SQL="$REPO_ROOT/hms-api/applications/hms/data/migrations/20261029-hms-commissions-payable-type-default.sql"
HOTFIX_SQL="$COMPOSE_DIR/postgres/external/hms-commissions-payable-hotfix.sql"
ACCT_MIN_SQL="$COMPOSE_DIR/postgres/external/hms-accounting-demo-minimum-hotfix.sql"
# --load-data file= must be a path UtilURL can resolve (not component://).
OFBIZ_DEMO_GL="file=/ofbiz/applications/datamodel/data/demo/GlAccountDemoData.xml"
OFBIZ_HMS_COA="file=/ofbiz/applications/hms/data/HmsCoaSeedData.xml"

cd "$COMPOSE_DIR"

if [[ ! -f docker-compose.yml ]]; then
  echo "ERROR: docker-compose.yml not found in $COMPOSE_DIR" >&2
  exit 1
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

DB_NAME="${OFBIZ_POSTGRES_OFBIZ_DB:-${DB_NAME:-ofbiz_hms}}"
API_JDBC_HOST="${OFBIZ_POSTGRES_HOST:-${DB_HOST:-localhost}}"
if [[ "$API_JDBC_HOST" == "host.docker.internal" ]]; then
  PGHOST="${NATIVE_POSTGRES_HOST:-localhost}"
  PGPORT="${NATIVE_POSTGRES_PORT:-${DB_PORT:-5432}}"
else
  PGHOST="$API_JDBC_HOST"
  PGPORT="${OFBIZ_POSTGRES_PORT:-${DB_PORT:-5432}}"
fi
PGUSER="${POSTGRES_ADMIN_USER:-${NATIVE_POSTGRES_ADMIN_USER:-postgres}}"

ofbiz_load() {
  echo ">>> OFBiz load: $* (may take several minutes; wait for process to exit)"
  docker_compose exec -T hms-api /ofbiz/bin/ofbiz \
    --load-data delegator=default \
    --load-data "$@"
}

# Prefer password auth; on local Postgres fall back to `sudo -u postgres` (peer auth on unix socket).
psql_admin() {
  local admin_pass="${POSTGRES_ADMIN_PASSWORD:-${NATIVE_POSTGRES_ADMIN_PASSWORD:-}}"
  if [[ -n "$admin_pass" ]]; then
    PGPASSWORD="$admin_pass" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
    return $?
  fi
  if [[ "$PGHOST" == "localhost" || "$PGHOST" == "127.0.0.1" ]] && command -v sudo >/dev/null; then
    sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
    return $?
  fi
  echo "ERROR: Set NATIVE_POSTGRES_ADMIN_PASSWORD in docker/.env, or run SQL as: sudo -u postgres psql -d $DB_NAME ..." >&2
  return 1
}

psql_q() {
  psql_admin -Atqc "$1"
}

echo "=== HMS commissions / COA fix ==="
echo "Database: $DB_NAME | API JDBC host: $API_JDBC_HOST | host psql: $PGHOST:$PGPORT"
if [[ "$API_JDBC_HOST" == "host.docker.internal" && "${NATIVE_POSTGRES_HOST:-localhost}" != "localhost" ]]; then
  echo "NOTE: Container reaches Postgres via host-gateway; host psql uses NATIVE_POSTGRES_HOST=$PGHOST."
fi
echo "Docker: $DOCKER_COMPOSE_BIN"
echo "Container: $(docker_compose ps -q hms-api 2>/dev/null || echo 'hms-api not running')"

if ! hms_api_container_up; then
  echo "ERROR: hms-api container is not up. Run: $DOCKER_COMPOSE_BIN up -d hms-api" >&2
  echo "If the stack was started with sudo, try: export DOCKER_COMPOSE_CMD='sudo docker compose'" >&2
  exit 1
fi

GL_COUNT="$(psql_q "SELECT COUNT(*) FROM gl_account;" 2>/dev/null || echo "0")"
HAS_210002="$(psql_q "SELECT COUNT(*) FROM gl_account WHERE gl_account_id = '210002';" 2>/dev/null || echo "0")"
echo "gl_account rows: $GL_COUNT | gl_account 210002: $HAS_210002"

if [[ "$GL_COUNT" == "0" ]]; then
  echo ">>> Empty chart: loading demo GL skeleton (GlAccountDemoData.xml)..."
  ofbiz_load "$OFBIZ_DEMO_GL"
  GL_COUNT="$(psql_q "SELECT COUNT(*) FROM gl_account;")"
  echo "gl_account rows after demo load: $GL_COUNT"
  if [[ "$GL_COUNT" == "0" ]]; then
    echo "ERROR: demo GL load did not populate gl_account. Check container logs." >&2
    exit 1
  fi
fi

HAS_210002="$(psql_q "SELECT COUNT(*) FROM gl_account WHERE gl_account_id = '210002';" 2>/dev/null || echo "0")"
ORG_210002="$(psql_q "SELECT COUNT(*) FROM gl_account_organization WHERE organization_party_id = 'Company' AND gl_account_id = '210002';" 2>/dev/null || echo "0")"
if [[ "$HAS_210002" == "0" || "$ORG_210002" == "0" ]]; then
  echo ">>> Loading HMS COA (HmsCoaSeedData.xml, includes 210002 + Company org links)..."
  ofbiz_load "$OFBIZ_HMS_COA"
  HAS_210002="$(psql_q "SELECT COUNT(*) FROM gl_account WHERE gl_account_id = '210002';")"
  ORG_210002="$(psql_q "SELECT COUNT(*) FROM gl_account_organization WHERE organization_party_id = 'Company' AND gl_account_id = '210002';")"
  echo "After HMS COA: gl_account 210002=$HAS_210002 | org link Company/210002=$ORG_210002"
  if [[ "$HAS_210002" == "0" || "$ORG_210002" == "0" ]]; then
    echo "ERROR: 210002 or Company org link still missing after HmsCoaSeedData load." >&2
    exit 1
  fi
fi

SQL_FILE=""
if [[ -f "$MIGRATION_SQL" ]]; then
  SQL_FILE="$MIGRATION_SQL"
elif [[ -f "$HOTFIX_SQL" ]]; then
  SQL_FILE="$HOTFIX_SQL"
fi
if [[ -f "$ACCT_MIN_SQL" ]]; then
  echo ">>> Applying minimum accounting defaults (invoice posting / CASH / fiscal period)..."
  psql_admin -f "$ACCT_MIN_SQL"
fi

if [[ -z "$SQL_FILE" ]]; then
  echo "WARN: no commissions SQL found — skip SQL step" >&2
else
  echo ">>> Applying COMMISSIONS_PAYABLE gl_account_type_default ($SQL_FILE)..."
  psql_admin -f "$SQL_FILE"
fi

echo ">>> Verification:"
psql_admin <<EOF
SELECT gl_account_id, gl_account_type_id, account_name
  FROM gl_account
 WHERE gl_account_id IN ('210002', '221100')
    OR gl_account_type_id = 'COMMISSIONS_PAYABLE';
SELECT * FROM gl_account_type_default
 WHERE gl_account_type_id = 'COMMISSIONS_PAYABLE' AND organization_party_id = 'Company';
EOF

echo "=== Done. Run ./scripts/verify-hms-commissions-gl-linux.sh then retry Collect Payment. ==="
echo "If verify shows DB OK but UI fails, rebuild API from fix/opd-encounter-sequence-and-commission-accounting:"
echo "  cd $REPO_ROOT/hms-api && git fetch && git checkout fix/opd-encounter-sequence-and-commission-accounting"
echo "  cd $COMPOSE_DIR && docker compose build --no-cache hms-api && docker compose up -d hms-api"

#!/usr/bin/env bash
# Diagnose COMMISSIONS_PAYABLE resolution for Collect Payment (matches HmsAccountingBridge logic).
# Run: cd /opt/HMS/docker && ./scripts/verify-hms-commissions-gl-linux.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/docker-compose.sh
source "$SCRIPT_DIR/lib/docker-compose.sh"

COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$COMPOSE_DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

DB_NAME="${OFBIZ_POSTGRES_OFBIZ_DB:-${DB_NAME:-ofbiz_hms}}"
API_PGHOST="${OFBIZ_POSTGRES_HOST:-${DB_HOST:-localhost}}"
NATIVE_PGHOST="${NATIVE_POSTGRES_HOST:-localhost}"
NATIVE_PGPORT="${NATIVE_POSTGRES_PORT:-5432}"
if [[ "$API_PGHOST" == "host.docker.internal" ]]; then
  HOST_PGHOST="$NATIVE_PGHOST"
  HOST_PGPORT="$NATIVE_PGPORT"
else
  HOST_PGHOST="$API_PGHOST"
  HOST_PGPORT="${OFBIZ_POSTGRES_PORT:-${DB_PORT:-5432}}"
fi
PGPORT="${OFBIZ_POSTGRES_PORT:-${DB_PORT:-5432}}"
APP_USER="${OFBIZ_POSTGRES_OFBIZ_USER:-${DB_USER:-hms_app}}"
APP_PASS="${OFBIZ_POSTGRES_OFBIZ_PASSWORD:-${DB_PASSWORD:-}}"
ADMIN_USER="${POSTGRES_ADMIN_USER:-${NATIVE_POSTGRES_ADMIN_USER:-postgres}}"
ADMIN_PASS="${POSTGRES_ADMIN_PASSWORD:-${NATIVE_POSTGRES_ADMIN_PASSWORD:-}}"

echo "=== COMMISSIONS_PAYABLE diagnostics ==="
echo "Docker: $DOCKER_COMPOSE_BIN"
echo "API JDBC: $DB_NAME @ $API_PGHOST:$PGPORT (user: $APP_USER)"
echo "Host psql: $DB_NAME @ $HOST_PGHOST:$HOST_PGPORT (same DB when API uses host.docker.internal)"
if [[ "$API_PGHOST" != "host.docker.internal" && "$NATIVE_PGHOST" != "$API_PGHOST" ]]; then
  echo "NOTE: NATIVE postgres is $NATIVE_PGHOST — may differ from API host $API_PGHOST."
fi

run_psql_at() {
  local host="$1" port="$2" user="$3" pass="$4"
  shift 4
  PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

run_psql() {
  run_psql_at "$HOST_PGHOST" "$HOST_PGPORT" "$1" "$2" "${@:3}"
}

echo ""
echo "--- 1) Resolver checks (organization Company) ---"
run_psql "$ADMIN_USER" "$ADMIN_PASS" <<'SQL'
\echo 'Step A: gl_account_type_default'
SELECT gl_account_type_id, organization_party_id, gl_account_id
  FROM gl_account_type_default
 WHERE gl_account_type_id = 'COMMISSIONS_PAYABLE' AND organization_party_id = 'Company';

\echo 'Step B: gl_account_organization for 210002'
SELECT organization_party_id, gl_account_id, from_date
  FROM gl_account_organization
 WHERE organization_party_id = 'Company' AND gl_account_id = '210002';

\echo 'Step C: any Company-linked COMMISSIONS_PAYABLE account'
SELECT ga.gl_account_id, ga.gl_account_type_id, ga.account_name
  FROM gl_account ga
  INNER JOIN gl_account_organization gao
    ON gao.gl_account_id = ga.gl_account_id AND gao.organization_party_id = 'Company'
 WHERE ga.gl_account_type_id = 'COMMISSIONS_PAYABLE'
 ORDER BY ga.gl_account_id;

\echo 'Counts'
SELECT COUNT(*) AS gl_account_total FROM gl_account;
SQL

if [[ -n "$APP_PASS" ]]; then
  echo ""
  echo "--- 2) Same counts as API DB user ($APP_USER) ---"
  run_psql "$APP_USER" "$APP_PASS" -c "SELECT COUNT(*) AS gl_account_visible_to_api FROM gl_account;"
  run_psql "$APP_USER" "$APP_PASS" -c "SELECT COUNT(*) AS org_link_210002 FROM gl_account_organization WHERE organization_party_id='Company' AND gl_account_id='210002';"
else
  echo "WARN: Set OFBIZ_POSTGRES_OFBIZ_PASSWORD in .env to test hms_app visibility."
fi

echo ""
echo "--- 3) JDBC database the running container actually uses ---"
if hms_api_container_up; then
  docker_compose exec -T hms-api sh -c '
    for f in /ofbiz/config/entityengine.xml /ofbiz/framework/entity/config/entityengine.xml; do
      if [ -f "$f" ]; then
        echo "entityengine: $f"
        grep -E "jdbc-uri|jdbc-uri" "$f" 2>/dev/null | head -3 || grep "jdbc:postgresql" "$f" | head -3
      fi
    done
    echo "OFBIZ_POSTGRES_OFBIZ_DB=${OFBIZ_POSTGRES_OFBIZ_DB:-<unset>}"
    echo "DB_NAME=${DB_NAME:-<unset>}"
  ' 2>/dev/null || echo "Could not read entityengine inside container."
else
  echo "hms-api container not running."
fi

echo ""
echo "--- 4) Deployed API includes GL resolver fix? ---"
if hms_api_container_up; then
  RESOLVER_FOUND="$(docker_compose exec -T hms-api sh -c '
    if grep -rq "resolveCommissionsPayableGlAccountId" /ofbiz/applications/hms 2>/dev/null; then
      echo YES_SOURCE
      exit 0
    fi
    for j in $(find /ofbiz -name "*.jar" 2>/dev/null); do
      if strings "$j" 2>/dev/null | grep -q "resolveCommissionsPayableGlAccountId"; then
        echo "YES_JAR:$j"
        exit 0
      fi
    done
    echo NO
  ' 2>/dev/null | head -1 || echo NO)"
  echo "resolveCommissionsPayableGlAccountId in image: $RESOLVER_FOUND"
  if [[ "$RESOLVER_FOUND" == NO ]]; then
    echo "Image is likely OLD (master without commission GL fallback)."
    echo "Fix: git checkout fix/opd-encounter-sequence-and-commission-accounting, then:"
    echo "     docker compose build --no-cache hms-api && docker compose up -d hms-api"
  fi
else
  echo "hms-api container not running."
fi

if [[ "$NATIVE_PGHOST" != "$API_PGHOST" ]] && [[ -n "$ADMIN_PASS" ]]; then
  echo ""
  echo "--- 5) Same checks on NATIVE host ($NATIVE_PGHOST) — often where pgAdmin connects ---"
  run_psql_at "$NATIVE_PGHOST" "$NATIVE_PGPORT" "$ADMIN_USER" "$ADMIN_PASS" <<'SQL' || true
SELECT current_database() AS db, inet_server_addr() AS server_ip, COUNT(*) AS gl_account_total FROM gl_account;
SQL
  echo "If gl_account_total differs from step 1, you patched the wrong PostgreSQL instance."
fi

echo ""
echo "--- 6) If Step A–C are empty OR gl_account_total=0, run apply script on API host ---"
echo "    ./scripts/apply-hms-commissions-coa-linux.sh"
echo "    (Manual INSERT into gl_account_type_default alone does nothing when gl_account is empty.)"
echo ""
echo "--- 7) If DB OK on API host but UI still fails: rebuild API from fix branch (step 4) ---"

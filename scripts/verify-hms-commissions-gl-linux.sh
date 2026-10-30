#!/usr/bin/env bash
# Diagnose COMMISSIONS_PAYABLE resolution for Collect Payment (matches HmsAccountingBridge logic).
# Run: cd /opt/HMS/docker && ./scripts/verify-hms-commissions-gl-linux.sh

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$COMPOSE_DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

DB_NAME="${OFBIZ_POSTGRES_OFBIZ_DB:-${DB_NAME:-ofbiz_hms}}"
PGHOST="${DB_HOST:-localhost}"
PGPORT="${DB_PORT:-5432}"
APP_USER="${OFBIZ_POSTGRES_OFBIZ_USER:-${DB_USER:-hms_app}}"
APP_PASS="${OFBIZ_POSTGRES_OFBIZ_PASSWORD:-${DB_PASSWORD:-}}"
ADMIN_USER="${POSTGRES_ADMIN_USER:-${NATIVE_POSTGRES_ADMIN_USER:-postgres}}"
ADMIN_PASS="${POSTGRES_ADMIN_PASSWORD:-${NATIVE_POSTGRES_ADMIN_PASSWORD:-}}"

echo "=== COMMISSIONS_PAYABLE diagnostics ==="
echo "DB: $DB_NAME @ $PGHOST:$PGPORT (API user: $APP_USER)"

run_psql() {
  local user="$1" pass="$2"
  PGPASSWORD="$pass" psql -h "$PGHOST" -p "$PGPORT" -U "$user" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
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
echo "--- 3) Deployed API includes GL resolver fix? ---"
if docker compose ps hms-api 2>/dev/null | grep -q 'Up'; then
  if docker compose exec -T hms-api sh -c 'find /ofbiz -name "*.jar" 2>/dev/null | while read j; do jar tf "$j" 2>/dev/null | grep -q "org/apache/ofbiz/hms/module/HmsAccountingBridge.class" && echo "FOUND HmsAccountingBridge in: $j"; done' | head -3; then
    :
  else
    echo "Could not locate HmsAccountingBridge.class in jars (layout may differ)."
  fi
  if docker compose exec -T hms-api sh -c 'grep -r "resolveCommissionsPayableGlAccountId" /ofbiz/applications/hms 2>/dev/null | head -1 || find /ofbiz -name "*.jar" -print0 2>/dev/null | xargs -0 -I{} sh -c "strings {} 2>/dev/null | grep -q resolveCommissionsPayableGlAccountId && echo FOUND_IN {}"' 2>/dev/null | head -5; then
    echo "If no FOUND line above, image is likely OLD (master without commission GL fallback)."
    echo "Fix: git pull fix/opd-encounter-sequence-and-commission-accounting in hms-api, then:"
    echo "     docker compose build --no-cache hms-api && docker compose up -d hms-api"
  fi
else
  echo "hms-api container not running."
fi

echo ""
echo "--- 4) If Step A–C are empty, run apply script ---"
echo "    ./scripts/apply-hms-commissions-coa-linux.sh"
echo ""
echo "--- 5) If DB OK but UI still fails: rebuild API from fix branch (see step 3) ---"

#!/usr/bin/env bash
# Verifies HMS subscription gating via login (bindTenant runs before credentials).
# Usage:
#   VERIFY_SUBSCRIPTION_MODE=expired  — expect HTTP 403 SUBSCRIPTION_EXPIRED
#   VERIFY_SUBSCRIPTION_MODE=active   — expect normal API access (no subscription block)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/.env"

API="${VERIFY_API_URL:-http://localhost:${HMS_API_PORT:-8080}}"
TENANT="${HMS_TENANT_ID:-hms}"
MODE="${VERIFY_SUBSCRIPTION_MODE:-}"

EXPIRED_MSG='Subscription Expired, Please contact your service provider.'
BODY_FILE="${TMPDIR:-/tmp}/hms-subscription-body.json"

if [[ -z "${MODE}" ]]; then
  if [[ "${SUBSCRIPTION_DAYS:-0}" =~ ^[1-9][0-9]*$ ]] \
    && [[ -n "${SUBSCRIPTION_START_DATE:-}" ]]; then
    MODE=expired
  else
    MODE=active
  fi
fi

login_probe() {
  curl -sS -o "${BODY_FILE}" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "{\"userLoginId\":\"admin\",\"password\":\"x\",\"userTenantId\":\"${TENANT}\"}" \
    "${API}/hms/control/login"
}

main_probe() {
  curl -sS -o /dev/null -w "%{http_code}" "${API}/hms/control/main"
}

if [[ "${MODE}" == "expired" ]]; then
  echo "POST ${API}/hms/control/login (expect HTTP 403 SUBSCRIPTION_EXPIRED)"
  HTTP=$(login_probe || true)
  echo "HTTP ${HTTP}"
  cat "${BODY_FILE}"
  echo

  FAIL=0
  [[ "${HTTP}" == "403" ]] || { echo "FAIL: expected HTTP 403, got ${HTTP}"; FAIL=1; }
  grep -q '"errorCode"[[:space:]]*:[[:space:]]*"SUBSCRIPTION_EXPIRED"' "${BODY_FILE}" \
    || { echo "FAIL: missing errorCode SUBSCRIPTION_EXPIRED"; FAIL=1; }
  grep -Fq "${EXPIRED_MSG}" "${BODY_FILE}" \
    || { echo "FAIL: missing exact expiry message"; FAIL=1; }
  [[ "${FAIL}" -eq 0 ]] && echo "OK: expired subscription response verified."
  exit "${FAIL}"
fi

if [[ "${MODE}" == "active" ]]; then
  echo "GET ${API}/hms/control/main (expect HTTP 200)"
  MAIN_HTTP=$(main_probe || true)
  echo "HTTP ${MAIN_HTTP}"
  [[ "${MAIN_HTTP}" == "200" ]] || { echo "FAIL: main endpoint not reachable"; exit 1; }

  echo "POST ${API}/hms/control/login (expect no SUBSCRIPTION_EXPIRED / not HTTP 403 for expiry)"
  HTTP=$(login_probe || true)
  echo "HTTP ${HTTP}"
  cat "${BODY_FILE}"
  echo

  if [[ "${HTTP}" == "403" ]] && grep -q 'SUBSCRIPTION_EXPIRED' "${BODY_FILE}"; then
    echo "FAIL: active subscription but login blocked as SUBSCRIPTION_EXPIRED"
    exit 1
  fi
  echo "OK: active subscription — API reachable and login not blocked by subscription expiry."
  exit 0
fi

echo "Unknown VERIFY_SUBSCRIPTION_MODE=${MODE} (use expired or active)"
exit 2

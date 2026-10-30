#!/usr/bin/env bash
# Shared by docker/scripts/*.sh — use when the login user needs `sudo docker compose`.

if [[ -n "${DOCKER_COMPOSE_BIN:-}" ]]; then
  :
elif [[ -n "${DOCKER_COMPOSE_CMD:-}" ]]; then
  DOCKER_COMPOSE_BIN="$DOCKER_COMPOSE_CMD"
elif docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE_BIN="docker compose"
elif sudo docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE_BIN="sudo docker compose"
else
  echo "ERROR: docker compose not available. Add your user to the docker group or set DOCKER_COMPOSE_CMD='sudo docker compose'." >&2
  return 1 2>/dev/null || exit 1
fi

docker_compose() {
  # shellcheck disable=SC2086
  $DOCKER_COMPOSE_BIN "$@"
}

hms_api_container_up() {
  if docker_compose ps hms-api 2>/dev/null | grep -qE '(Up|running)'; then
    return 0
  fi
  # Stack often started with sudo while this script auto-picked plain `docker compose`.
  if [[ "${DOCKER_COMPOSE_BIN:-}" != "sudo docker compose" ]] && command -v sudo >/dev/null 2>&1; then
    if sudo docker compose ps hms-api 2>/dev/null | grep -qE '(Up|running)'; then
      echo "Note: using 'sudo docker compose' (hms-api visible only to root compose)." >&2
      DOCKER_COMPOSE_BIN="sudo docker compose"
      export DOCKER_COMPOSE_BIN
      return 0
    fi
  fi
  return 1
}

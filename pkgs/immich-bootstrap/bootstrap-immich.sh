#!/usr/bin/env bash
# Create the first Immich admin so OAuth auto-launch can take over.
set -euo pipefail

IMMICH_URL="${IMMICH_URL:-http://127.0.0.1:2283}"
ADMIN_EMAIL="${ADMIN_EMAIL:?ADMIN_EMAIL is required}"
ADMIN_NAME="${ADMIN_NAME:?ADMIN_NAME is required}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
STATE_FILE="${STATE_FILE:-/var/lib/immich/.lanbat-bootstrap-complete}"

log() {
  echo "immich-bootstrap: $*"
}

wait_for_immich() {
  local attempt
  for attempt in $(seq 1 60); do
    if curl -fsS -o /dev/null "${IMMICH_URL}/api/server/ping"; then
      return 0
    fi
    sleep 5
  done
  log "Immich did not become ready"
  return 1
}

is_initialized() {
  curl -fsS "${IMMICH_URL}/api/server/config" | jq -e '.isInitialized == true' >/dev/null
}

if [[ -f "$STATE_FILE" ]] && is_initialized; then
  log "already initialized"
  exit 0
fi

wait_for_immich

if is_initialized; then
  log "admin already exists"
  install -d -m 0750 "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  exit 0
fi

log "creating bootstrap admin ${ADMIN_EMAIL}"
payload="$(jq -n \
  --arg email "$ADMIN_EMAIL" \
  --arg name "$ADMIN_NAME" \
  --arg password "$ADMIN_PASSWORD" \
  '{email: $email, name: $name, password: $password}')"

curl -fsS -X POST "${IMMICH_URL}/api/auth/admin-sign-up" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  >/dev/null

install -d -m 0750 "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"
log "done"

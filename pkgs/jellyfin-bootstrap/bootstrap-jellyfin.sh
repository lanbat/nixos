#!/usr/bin/env bash
# Complete Jellyfin first-run startup wizard (admin user, locale, remote access).
set -euo pipefail

JELLYFIN_URL="${JELLYFIN_URL:-http://127.0.0.1:8096}"
OWNER_USERNAME="${OWNER_USERNAME:?OWNER_USERNAME is required}"
OWNER_PASSWORD="${OWNER_PASSWORD:?OWNER_PASSWORD is required}"
STATE_FILE="${STATE_FILE:-/var/lib/jellyfin/.lanbat-bootstrap-complete}"

log() {
  echo "jellyfin-bootstrap: $*"
}

wait_for_jellyfin() {
  local attempt
  for attempt in $(seq 1 60); do
    if curl -fsS -o /dev/null "${JELLYFIN_URL}/health"; then
      return 0
    fi
    sleep 5
  done
  log "Jellyfin did not become ready"
  return 1
}

# The public endpoint: /System/Info needs a login, so without one the wizard
# always looked incomplete, and the startup calls then failed with 401 on a
# set-up server.
wizard_complete() {
  curl -fsS "${JELLYFIN_URL}/System/Info/Public" | jq -e '.StartupWizardCompleted == true' >/dev/null
}

run_startup_wizard() {
  log "setting locale and metadata language"
  curl -fsS -X POST "${JELLYFIN_URL}/Startup/Configuration" \
    -H 'Content-Type: application/json' \
    -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' \
    >/dev/null

  log "initializing admin user record"
  curl -fsS "${JELLYFIN_URL}/Startup/User" >/dev/null

  log "creating admin user ${OWNER_USERNAME}"
  curl -fsS -X POST "${JELLYFIN_URL}/Startup/User" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n \
      --arg name "$OWNER_USERNAME" \
      --arg password "$OWNER_PASSWORD" \
      '{Name: $name, Password: $password}')" \
    >/dev/null

  log "disabling UPnP port mapping (Caddy handles exposure)"
  curl -fsS -X POST "${JELLYFIN_URL}/Startup/RemoteAccess" \
    -H 'Content-Type: application/json' \
    -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' \
    >/dev/null

  log "completing startup wizard"
  curl -fsS -X POST "${JELLYFIN_URL}/Startup/Complete" >/dev/null
}

if [[ -f "$STATE_FILE" ]] && wizard_complete; then
  log "already initialized"
  exit 0
fi

wait_for_jellyfin

if wizard_complete; then
  log "startup wizard already complete"
  install -d -m 0750 "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  exit 0
fi

run_startup_wizard

install -d -m 0750 "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"
log "done"

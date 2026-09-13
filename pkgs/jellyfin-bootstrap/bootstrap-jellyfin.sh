#!/usr/bin/env bash
# Complete Jellyfin first-run setup: wizard, media libraries, plugins, and SSO.
set -euo pipefail

JELLYFIN_URL="${JELLYFIN_URL:-http://127.0.0.1:8096}"
EXTERNAL_URL="${EXTERNAL_URL:?EXTERNAL_URL is required}"
AUTH_DOMAIN="${AUTH_DOMAIN:?AUTH_DOMAIN is required}"
OWNER_USERNAME="${OWNER_USERNAME:?OWNER_USERNAME is required}"
OWNER_PASSWORD="${OWNER_PASSWORD:?OWNER_PASSWORD is required}"
AUTHENTIK_JELLYFIN_CLIENT_SECRET="${AUTHENTIK_JELLYFIN_CLIENT_SECRET:?AUTHENTIK_JELLYFIN_CLIENT_SECRET is required}"
STATE_DIR="${STATE_DIR:-/var/lib/jellyfin}"
WIZARD_STATE_FILE="${WIZARD_STATE_FILE:-${STATE_DIR}/.lanbat-bootstrap-complete}"
CONFIG_STATE_FILE="${CONFIG_STATE_FILE:-${STATE_DIR}/.lanbat-jellyfin-config-complete}"

EMBY_CLIENT='MediaBrowser Client="lanbat-bootstrap", Device="server", DeviceId="lanbat", Version="10.11.7"'
API_KEY_APP="lanbat-bootstrap"

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

wizard_complete() {
  curl -fsS "${JELLYFIN_URL}/System/Info/Public" | jq -e '.StartupWizardCompleted == true' >/dev/null
}

api_auth() {
  local token
  token="$(curl -fsS -X POST "${JELLYFIN_URL}/Users/AuthenticateByName" \
    -H "Content-Type: application/json" \
    -H "X-Emby-Authorization: ${EMBY_CLIENT}" \
    -d "$(jq -n \
      --arg u "$OWNER_USERNAME" \
      --arg p "$OWNER_PASSWORD" \
      '{Username: $u, Pw: $p}')" \
    | jq -r .AccessToken)"
  AUTH_HEADER="${EMBY_CLIENT}, Token=\"${token}\""
}

api_call() {
  curl -fsS "$@" -H "X-Emby-Authorization: ${AUTH_HEADER}"
}

ensure_api_key() {
  local existing
  existing="$(api_call "${JELLYFIN_URL}/Auth/Keys" | jq -r --arg app "$API_KEY_APP" '
    [.Items[] | select(.AppName == $app) | .AccessToken] | last // empty
  ')"
  if [[ -n "$existing" ]]; then
    API_KEY="$existing"
    return 0
  fi
  api_call -X POST "${JELLYFIN_URL}/Auth/Keys?app=${API_KEY_APP}" -o /dev/null
  API_KEY="$(api_call "${JELLYFIN_URL}/Auth/Keys" | jq -r --arg app "$API_KEY_APP" '
    [.Items[] | select(.AppName == $app) | .AccessToken] | last
  ')"
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

library_exists() {
  local name="$1"
  api_call "${JELLYFIN_URL}/Library/VirtualFolders" | jq -e --arg name "$name" '.[] | select(.Name == $name)' >/dev/null
}

add_library() {
  local collection_type="$1"
  local name="$2"
  local path="$3"

  if [[ ! -d "$path" ]]; then
    log "skipping library ${name} (${path} not mounted yet)"
    return 0
  fi
  if library_exists "$name"; then
    log "library ${name} already exists"
    return 0
  fi

  log "adding library ${name} -> ${path}"
  api_call -X POST \
    "${JELLYFIN_URL}/Library/VirtualFolders?collectionType=${collection_type}&name=$(jq -rn --arg v "$name" '$v|@uri')&refreshLibrary=false" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg path "$path" '{LibraryOptions: {PathInfos: [{Path: $path}]}}')" \
    -o /dev/null
}

setup_libraries() {
  add_library movies "Movies" "/srv/storage/a/media/movies"
  add_library tvshows "TV Shows" "/srv/storage/a/media/tv"
  add_library musicvideos "Music Videos" "/srv/storage/a/media/music-videos"
  add_library music "Music" "/srv/storage/b/media/music"
  add_library movies "Documentaries" "/srv/storage/b/media/documentaries"
  add_library books "Audiobooks" "/srv/storage/b/media/audiobooks"
  add_library books "Books" "/srv/storage/b/media/books"
}

uri_encode() {
  jq -rn --arg v "$1" '$v|@uri'
}

plugin_installed() {
  local name="$1"
  if compgen -G "${STATE_DIR}/plugins/${name}_*" >/dev/null; then
    return 0
  fi
  api_call "${JELLYFIN_URL}/Packages/Installed/$(uri_encode "$name")" >/dev/null 2>&1
}

install_plugin() {
  local name="$1"
  local guid="${2:-}"
  local query=""
  if [[ -n "$guid" ]]; then
    query="?assemblyGuid=${guid}"
  fi
  if plugin_installed "$name"; then
    log "plugin ${name} already installed"
    return 1
  fi
  log "installing plugin ${name}"
  api_call -X POST "${JELLYFIN_URL}/Packages/Installed/$(uri_encode "$name")${query}" -o /dev/null
  return 0
}

setup_plugin_repositories() {
  local version sso_repo sso_name
  version="$(curl -fsS "${JELLYFIN_URL}/System/Info/Public" | jq -r .Version)"
  if [[ "$version" == 12.* ]]; then
    sso_repo="https://raw.githubusercontent.com/Flowfin/jellyfin-plugin-sso/manifest-beta/manifest.json"
    sso_name="Flowfin SSO"
  else
    sso_repo="https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json"
    sso_name="SSO Auth"
  fi

  api_call -X POST "${JELLYFIN_URL}/Repositories" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg sso_repo "$sso_repo" --arg sso_name "$sso_name" '[
      {
        Name: "Jellyfin Stable",
        Url: "https://repo.jellyfin.org/files/plugin/manifest.json",
        Enabled: true
      },
      {
        Name: $sso_name,
        Url: $sso_repo,
        Enabled: true
      }
    ]')" \
    -o /dev/null
}

setup_plugins() {
  local restarted=false
  setup_plugin_repositories

  install_plugin "Open Subtitles" "4b9ed42f518548b598036ff2989014c4" && restarted=true
  install_plugin "Trakt" "4fe3201ed6ae4f2e8917e12bda571281" && restarted=true

  local version
  version="$(curl -fsS "${JELLYFIN_URL}/System/Info/Public" | jq -r .Version)"
  if [[ "$version" == 12.* ]]; then
    install_plugin "Community SSO for Jellyfin" "505ce9d1-d916-42fa-86ca-673ef241d7df" && restarted=true
  else
    install_plugin "SSO Authentication" "505ce9d1-d916-42fa-86ca-673ef241d7df" && restarted=true
  fi

  if [[ "$restarted" == true ]]; then
    log "restarting Jellyfin to load new plugins"
    systemctl restart jellyfin.service
    wait_for_jellyfin
    local attempt
    for attempt in $(seq 1 12); do
      if api_auth 2>/dev/null; then
        return 0
      fi
      sleep 5
    done
    log "Jellyfin API did not accept authentication after plugin restart"
    return 1
  fi
}

sso_configured() {
  ensure_api_key
  curl -fsS "${JELLYFIN_URL}/sso/OID/Get?api_key=${API_KEY}" \
    | jq -e '.authentik.Enabled == true' >/dev/null
}

configuration_complete() {
  api_auth
  library_exists "Movies" \
    && plugin_installed "Open Subtitles" \
    && sso_configured
}

setup_sso() {
  if sso_configured; then
    log "Authentik SSO provider already configured"
    return 0
  fi

  ensure_api_key
  log "configuring Authentik OIDC provider"
  curl -fsS -X POST "${JELLYFIN_URL}/sso/OID/Add/authentik?api_key=${API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n \
      --arg endpoint "https://auth.${AUTH_DOMAIN}/application/o/jellyfin/" \
      --arg clientId "jellyfin" \
      --arg secret "$AUTHENTIK_JELLYFIN_CLIENT_SECRET" \
      '{
        oidEndpoint: $endpoint,
        oidClientId: $clientId,
        oidSecret: $secret,
        enabled: true,
        enableAuthorization: true,
        enableAllFolders: true,
        oidScopes: ["openid", "profile", "email"]
      }')" \
    -o /dev/null
}

setup_branding() {
  local disclaimer
  disclaimer="$(cat <<EOF
<form action="${EXTERNAL_URL}/sso/OID/start/authentik">
  <button class="raised block emby-button button-submit" type="submit">
    Sign in with Authentik
  </button>
</form>
EOF
)"
  api_call -X POST "${JELLYFIN_URL}/Branding/Configuration" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n \
      --arg disclaimer "$disclaimer" \
      '{
        LoginDisclaimer: $disclaimer,
        CustomCss: "a.raised.emby-button { padding: 0.9em 1em; color: inherit !important; } .disclaimerContainer { display: block; }"
      }')" \
    -o /dev/null || true
}

harden_adult_permissions() {
  local adult="/srv/storage/b/media/adult"
  if [[ ! -d "$adult" ]]; then
    return 0
  fi
  log "restricting ${adult} to the private group"
  chgrp private "$adult" 2>/dev/null || true
  chmod 2770 "$adult" 2>/dev/null || true
}

run_configuration() {
  harden_adult_permissions
  api_auth
  setup_libraries
  setup_plugins
  setup_sso
  setup_branding
}

wait_for_jellyfin

if [[ -f "$CONFIG_STATE_FILE" ]] && wizard_complete && configuration_complete 2>/dev/null; then
  log "configuration already complete"
  exit 0
fi

if wizard_complete || [[ -f "$WIZARD_STATE_FILE" ]]; then
  if ! wizard_complete; then
    log "waiting for Jellyfin to finish starting"
    wait_for_jellyfin
  fi
  install -d -m 0750 "$STATE_DIR"
  touch "$WIZARD_STATE_FILE"
else
  run_startup_wizard
  install -d -m 0750 "$STATE_DIR"
  touch "$WIZARD_STATE_FILE"
  log "startup wizard complete"
fi

run_configuration

install -d -m 0750 "$STATE_DIR"
touch "$CONFIG_STATE_FILE"
log "done"

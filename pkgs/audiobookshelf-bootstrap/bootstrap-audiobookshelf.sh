#!/usr/bin/env bash
# Complete Audiobookshelf setup: root account, Authentik OIDC, and the
# audiobook library, scanned.
#
# With MATCH_ONLY=1 it instead runs "Match books" on the library
# (audiobookshelf-match), which needs the setup done already.
set -euo pipefail

ABS_URL="${ABS_URL:-http://127.0.0.1:13378}"
AUTH_URL="${AUTH_URL:?AUTH_URL is required}"
EXTERNAL_URL="${EXTERNAL_URL:?EXTERNAL_URL is required}"
LIBRARY_PATH="${LIBRARY_PATH:?LIBRARY_PATH is required}"
LIBRARY_NAME="${LIBRARY_NAME:-Audiobooks}"
METADATA_PROVIDER="${METADATA_PROVIDER:-audible}"
OWNER_USERNAME="${OWNER_USERNAME:?OWNER_USERNAME is required}"
OWNER_PASSWORD="${OWNER_PASSWORD:?OWNER_PASSWORD is required}"
MATCH_ONLY="${MATCH_ONLY:-}"

# The library is on NFS, which has no inotify: scan on a schedule instead of
# watching (every two hours, like Jellyfin's libraries).
SCAN_CRON="0 */2 * * *"

log() {
  echo "audiobookshelf-bootstrap: $*"
}

wait_for_audiobookshelf() {
  local attempt
  for attempt in $(seq 1 60); do
    if curl -fsS -o /dev/null "${ABS_URL}/healthcheck"; then
      return 0
    fi
    sleep 5
  done
  log "Audiobookshelf did not become ready (tried ${attempt} times)"
  return 1
}

initialized() {
  curl -fsS "${ABS_URL}/status" | jq -e '.isInit == true' >/dev/null
}

create_root_user() {
  log "creating the root account ${OWNER_USERNAME}"
  curl -fsS -X POST "${ABS_URL}/init" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg u "$OWNER_USERNAME" --arg p "$OWNER_PASSWORD" \
      '{newRoot: {username: $u, password: $p}}')" \
    -o /dev/null
}

login() {
  TOKEN="$(curl -fsS -X POST "${ABS_URL}/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg u "$OWNER_USERNAME" --arg p "$OWNER_PASSWORD" \
      '{username: $u, password: $p}')" \
    | jq -r '.user.accessToken // .user.token // empty')"
  if [[ -z "$TOKEN" ]]; then
    log "logging in as ${OWNER_USERNAME} returned no token"
    return 1
  fi
}

api() {
  curl -fsS "$@" -H "Authorization: Bearer ${TOKEN}"
}

library_id() {
  api "${ABS_URL}/api/libraries" | jq -r --arg name "$LIBRARY_NAME" '
    [.libraries[] | select(.name == $name) | .id][0] // empty
  '
}

library_settings() {
  jq -n --arg cron "$SCAN_CRON" '{
    disableWatcher: true,
    autoScanCronExpression: $cron,
    skipMatchingMediaWithAsin: true,
    skipMatchingMediaWithIsbn: true
  }'
}

ensure_library() {
  LIBRARY_ID="$(library_id)"
  if [[ -z "$LIBRARY_ID" ]]; then
    if [[ ! -d "$LIBRARY_PATH" ]]; then
      log "${LIBRARY_PATH} does not exist"
      return 1
    fi
    log "adding library ${LIBRARY_NAME} -> ${LIBRARY_PATH}"
    api -X POST "${ABS_URL}/api/libraries" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n \
        --arg name "$LIBRARY_NAME" \
        --arg path "$LIBRARY_PATH" \
        --arg provider "$METADATA_PROVIDER" \
        --argjson settings "$(library_settings)" \
        '{name: $name, folders: [{fullPath: $path}], mediaType: "book",
          icon: "audiobookshelf", provider: $provider, settings: $settings}')" \
      -o /dev/null
    LIBRARY_ID="$(library_id)"
    return 0
  fi

  # An existing library keeps its folders; the provider and the settings
  # above follow this configuration.
  local current
  current="$(api "${ABS_URL}/api/libraries/${LIBRARY_ID}")"
  if jq -e --arg provider "$METADATA_PROVIDER" --argjson settings "$(library_settings)" '
    .provider == $provider and (.settings | contains($settings))
  ' <<<"$current" >/dev/null; then
    return 0
  fi
  log "updating library ${LIBRARY_NAME} (provider ${METADATA_PROVIDER}, scheduled scans)"
  api -X PATCH "${ABS_URL}/api/libraries/${LIBRARY_ID}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg provider "$METADATA_PROVIDER" --argjson settings "$(library_settings)" \
      '{provider: $provider, settings: $settings}')" \
    -o /dev/null
}

# authOpenIDSubfolderForRedirectURLs prefixes the callback path; Audiobookshelf
# leaves it undefined until set, and then sends Authentik a callback under
# "/undefined/", which Authentik rejects. Its web form sets "" for a server at
# the root of its domain, as this one is.
#
# Users sign in through Authentik (client "audiobookshelf"); an Authentik
# user whose username matches an account gets that account, and anyone else
# Authentik admits gets a new one. Password login stays as the fallback.
configure_oidc() {
  local secret="${AUTHENTIK_AUDIOBOOKSHELF_CLIENT_SECRET:-}"
  if [[ -z "$secret" ]]; then
    log "AUTHENTIK_AUDIOBOOKSHELF_CLIENT_SECRET is missing from authentik-oidc-secrets"
    return 1
  fi
  local app="${AUTH_URL}/application/o"
  local desired current
  desired="$(jq -n \
    --arg issuer "${app}/audiobookshelf/" \
    --arg authorize "${app}/authorize/" \
    --arg token "${app}/token/" \
    --arg userinfo "${app}/userinfo/" \
    --arg jwks "${app}/audiobookshelf/jwks/" \
    --arg logout "${app}/audiobookshelf/end-session/" \
    --arg secret "$secret" \
    '{
      authActiveAuthMethods: ["local", "openid"],
      authOpenIDIssuerURL: $issuer,
      authOpenIDAuthorizationURL: $authorize,
      authOpenIDTokenURL: $token,
      authOpenIDUserInfoURL: $userinfo,
      authOpenIDJwksURL: $jwks,
      authOpenIDLogoutURL: $logout,
      authOpenIDClientID: "audiobookshelf",
      authOpenIDClientSecret: $secret,
      authOpenIDTokenSigningAlgorithm: "RS256",
      authOpenIDButtonText: "Sign in with Authentik",
      authOpenIDAutoLaunch: false,
      authOpenIDAutoRegister: true,
      authOpenIDMatchExistingBy: "username",
      authOpenIDMobileRedirectURIs: ["audiobookshelf://oauth"],
      authOpenIDSubfolderForRedirectURLs: ""
    }')"
  current="$(api "${ABS_URL}/api/auth-settings")"
  if jq -e --argjson want "$desired" '
    . as $have
    | ($want | to_entries | all(
        if .key == "authActiveAuthMethods" or .key == "authOpenIDMobileRedirectURIs"
        then ($have[.key] | sort) == (.value | sort)
        else $have[.key] == .value end))
  ' <<<"$current" >/dev/null; then
    return 0
  fi
  log "configuring Authentik OIDC login"
  api -X PATCH "${ABS_URL}/api/auth-settings" \
    -H 'Content-Type: application/json' \
    -d "$desired" \
    -o /dev/null
}

scanning() {
  api "${ABS_URL}/api/tasks" | jq -e --arg id "$LIBRARY_ID" '
    any(.tasks[]; .action == "library-scan" and .data.libraryId == $id and (.isFinished | not))
  ' >/dev/null
}

scan_library() {
  log "scanning ${LIBRARY_NAME}"
  api -X POST "${ABS_URL}/api/libraries/${LIBRARY_ID}/scan" -o /dev/null
  local attempt
  for attempt in $(seq 1 360); do
    sleep 5
    scanning || return 0
  done
  log "the scan is still running after 30 minutes; leaving it to finish"
}

# "Match books": look up every book without an ASIN or ISBN at the provider
# and fill in what its tags lack. It runs in the background.
match_library() {
  log "matching ${LIBRARY_NAME} against ${METADATA_PROVIDER}"
  api "${ABS_URL}/api/libraries/${LIBRARY_ID}/matchall" -o /dev/null
}

wait_for_audiobookshelf

if [[ -n "$MATCH_ONLY" ]]; then
  login
  LIBRARY_ID="$(library_id)"
  if [[ -z "$LIBRARY_ID" ]]; then
    log "no ${LIBRARY_NAME} library yet"
    exit 0
  fi
  match_library
  exit 0
fi

initialized || create_root_user
login
configure_oidc
# The unit binds to the drive's NFS mount, so a missing folder is an error
# worth retrying rather than a reason to finish without the library.
ensure_library || exit 1
scan_library
log "done"

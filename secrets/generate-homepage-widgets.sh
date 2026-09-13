#!/usr/bin/env bash
# secrets/generate-homepage-widgets.sh
#
# Populate homepage-widgets-env.age with API keys/tokens for Homepage widgets.
# Run from the repo root after services are deployed and bootstrapped.
#
# Usage:
#   bash secrets/generate-homepage-widgets.sh [server-host]
#
# The script SSHes to the server (default: admin@192.168.1.10 from local.nix),
# creates or reuses service API keys where possible, then writes
# secrets/homepage-widgets-env.age via agenix.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/secrets"

SERVER_HOST="${1:-}"
if [[ -z "$SERVER_HOST" ]]; then
  if [[ -f ../local.nix ]]; then
    SERVER_IP="$(sed -n 's/.*serverIp *= *"\([^"]*\)".*/\1/p' ../local.nix | head -1)"
    SERVER_HOST="admin@${SERVER_IP:-192.168.1.10}"
  else
    SERVER_HOST="admin@192.168.1.10"
  fi
fi

AGENIX="agenix"
if ! command -v agenix &>/dev/null; then
  echo "ERROR: agenix not found. Run from the dev shell: nix develop"
  exit 1
fi

if [[ ! -f secrets.nix ]]; then
  echo "ERROR: secrets/secrets.nix not found."
  exit 1
fi

read_secret_file() {
  local file="$1"
  local var="${2:-}"
  ssh -o BatchMode=yes "$SERVER_HOST" "sudo cat /run/agenix/${file} 2>/dev/null" \
    | if [[ -n "$var" ]]; then
      sed -n "s/^${var}=//p"
    else
      cat
    fi
}

write_env_value() {
  local key="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "  SKIP  ${key} (empty)"
    return
  fi
  ENV_LINES+=("${key}=${value}")
  echo "  OK    ${key}"
}

ENV_LINES=()

IMMICH_ADMIN_EMAIL=""
if [[ -f ../local.nix ]]; then
  IMMICH_ADMIN_EMAIL="$(sed -n 's/.*adminEmail *= *"\([^"]*\)".*/\1/p' ../local.nix | head -1)"
fi

echo "Collecting Homepage widget credentials from ${SERVER_HOST}..."
echo

# ---- Jellyfin ----
JELLYFIN_KEY="$(ssh -o BatchMode=yes "$SERVER_HOST" 'bash -s' <<'EOF'
set -euo pipefail
JELLYFIN_URL="http://127.0.0.1:8096"
OWNER_USERNAME="$(sudo sed -n "s/^OWNER_USERNAME=//p" /run/agenix/hass-bootstrap-env 2>/dev/null || true)"
OWNER_PASSWORD="$(sudo sed -n "s/^OWNER_PASSWORD=//p" /run/agenix/hass-bootstrap-env 2>/dev/null || true)"
if [[ -z "$OWNER_USERNAME" || -z "$OWNER_PASSWORD" ]]; then
  exit 0
fi
curl -fsS "${JELLYFIN_URL}/System/Info/Public" | jq -e '.StartupWizardCompleted == true' >/dev/null || exit 0
EMBY_CLIENT='MediaBrowser Client="lanbat-homepage", Device="server", DeviceId="lanbat-homepage", Version="10.11.7"'
TOKEN="$(curl -fsS -X POST "${JELLYFIN_URL}/Users/AuthenticateByName" \
  -H "Content-Type: application/json" \
  -H "X-Emby-Authorization: ${EMBY_CLIENT}" \
  -d "$(jq -n --arg u "$OWNER_USERNAME" --arg p "$OWNER_PASSWORD" '{Username: $u, Pw: $p}')" \
  | jq -r .AccessToken)"
AUTH_HEADER="${EMBY_CLIENT}, Token=\"${TOKEN}\""
EXISTING="$(curl -fsS "${JELLYFIN_URL}/Auth/Keys" -H "X-Emby-Authorization: ${AUTH_HEADER}" \
  | jq -r --arg app "homepage" '[.Items[] | select(.AppName == $app) | .AccessToken] | last // empty')"
if [[ -n "$EXISTING" ]]; then
  printf '%s' "$EXISTING"
  exit 0
fi
curl -fsS -X POST "${JELLYFIN_URL}/Auth/Keys?app=homepage" \
  -H "X-Emby-Authorization: ${AUTH_HEADER}" -o /dev/null
curl -fsS "${JELLYFIN_URL}/Auth/Keys" -H "X-Emby-Authorization: ${AUTH_HEADER}" \
  | jq -r --arg app "homepage" '[.Items[] | select(.AppName == $app) | .AccessToken] | last'
EOF
)" || true
write_env_value "JELLYFIN_API_KEY" "$JELLYFIN_KEY"

# ---- Immich ----
IMMICH_KEY="$(ssh -o BatchMode=yes "$SERVER_HOST" \
  "ADMIN_EMAIL='${IMMICH_ADMIN_EMAIL}' bash -s" <<'EOF'
set -euo pipefail
IMMICH_URL="http://127.0.0.1:2283"
curl -fsS -o /dev/null "${IMMICH_URL}/api/server/ping" || exit 0
ADMIN_PASSWORD="$(sudo sed -n 's/^OWNER_PASSWORD=//p' /run/agenix/hass-bootstrap-env 2>/dev/null || true)"
if [[ -z "$ADMIN_EMAIL" || -z "$ADMIN_PASSWORD" ]]; then
  exit 0
fi
ACCESS_TOKEN="$(curl -fsS -X POST "${IMMICH_URL}/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg email "$ADMIN_EMAIL" --arg password "$ADMIN_PASSWORD" '{email: $email, password: $password}')" \
  | jq -r .accessToken // empty)"
[[ -n "$ACCESS_TOKEN" ]] || exit 0
EXISTING="$(curl -fsS "${IMMICH_URL}/api/api-keys" \
  -H "x-api-key: ${ACCESS_TOKEN}" \
  | jq -r '.[] | select(.name == "homepage") | .token' | head -1)"
if [[ -n "$EXISTING" ]]; then
  printf '%s' "$EXISTING"
  exit 0
fi
curl -fsS -X POST "${IMMICH_URL}/api/api-keys" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${ACCESS_TOKEN}" \
  -d '{"name":"homepage","permissions":["server.statistics"]}' \
  | jq -r .secret // .token // empty
EOF
)" || true
write_env_value "IMMICH_API_KEY" "$IMMICH_KEY"

# ---- Home Assistant ----
DOMAIN="$(sed -n 's/.*domain *= *"\([^"]*\)".*/\1/p' ../local.nix | head -1)"
HA_OWNER_USERNAME="$(read_secret_file hass-bootstrap-env OWNER_USERNAME || true)"
HA_OWNER_PASSWORD="$(read_secret_file hass-bootstrap-env OWNER_PASSWORD || true)"
HA_TOKEN=""
if [[ -n "$DOMAIN" && -n "$HA_OWNER_USERNAME" && -n "$HA_OWNER_PASSWORD" ]]; then
  CREATE_HA_TOKEN="$(
    cd "$ROOT" && nix build --impure --no-link --print-out-paths -f - <<'EOF'
{ pkgs ? import <nixpkgs> {} }:
let cfg = import ./pkgs/homepage-config { inherit pkgs; };
in cfg.createHaToken
EOF
  )"
  TUNNEL_PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  ssh -f -N -o BatchMode=yes -L "${TUNNEL_PORT}:127.0.0.1:8123" "$SERVER_HOST" || true
  sleep 1
  HA_TOKEN="$(
    OWNER_USERNAME="$HA_OWNER_USERNAME" \
    OWNER_PASSWORD="$HA_OWNER_PASSWORD" \
    HA_URL="http://127.0.0.1:${TUNNEL_PORT}" \
    HA_PUBLIC_URL="https://ha.${DOMAIN}" \
    TOKEN_CLIENT_NAME="homepage" \
    "$CREATE_HA_TOKEN" 2>/dev/null || true
  )"
  pkill -f "ssh -f -N -o BatchMode=yes -L ${TUNNEL_PORT}:127.0.0.1:8123 ${SERVER_HOST}" 2>/dev/null || true
fi
write_env_value "HA_LONG_LIVED_TOKEN" "$HA_TOKEN"

# ---- Syncthing ----
SYNCTHING_KEY="$(ssh -o BatchMode=yes "$SERVER_HOST" \
  "sudo grep -oP '(?<=<apikey>)[^<]+' /var/lib/syncthing/.config/syncthing/config.xml 2>/dev/null | head -1" \
  || true)"
write_env_value "SYNCTHING_API_KEY" "$SYNCTHING_KEY"

# ---- qBittorrent ----
QBT_PASSWORD="$(read_secret_file hass-bootstrap-env OWNER_PASSWORD || true)"
write_env_value "QBITTORRENT_PASSWORD" "$QBT_PASSWORD"

# Preserve existing Authentik key if we already have one.
AUTHENTIK_KEY=""
if [[ -f homepage-widgets-env.age ]]; then
  AUTHENTIK_KEY="$($AGENIX -d homepage-widgets-env.age 2>/dev/null | sed -n 's/^AUTHENTIK_API_KEY=//p' || true)"
fi
if [[ -z "$AUTHENTIK_KEY" ]]; then
  echo "  MANUAL AUTHENTIK_API_KEY"
  echo "        Create an API token in Authentik: Admin → Directory → Tokens & App passwords"
  echo "        Intent: API Token. Permissions: view User, view Event."
  echo "        Then run: agenix -e secrets/homepage-widgets-env.age"
else
  write_env_value "AUTHENTIK_API_KEY" "$AUTHENTIK_KEY"
fi

if [[ ${#ENV_LINES[@]} -eq 0 ]]; then
  echo
  echo "No widget credentials were collected."
  exit 1
fi

CONTENT="$(printf '%s\n' "${ENV_LINES[@]}")"
if [[ -f homepage-widgets-env.age ]]; then
  EXISTING="$($AGENIX -d homepage-widgets-env.age 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    key="${line%%=*}"
    if ! printf '%s\n' "${ENV_LINES[@]}" | grep -q "^${key}="; then
      ENV_LINES+=("$line")
    fi
  done <<< "$EXISTING"
  CONTENT="$(printf '%s\n' "${ENV_LINES[@]}")"
fi

printf '%s' "$CONTENT" | $AGENIX -e homepage-widgets-env.age
echo
echo "Wrote secrets/homepage-widgets-env.age"
echo "Redeploy the server, then restart Homepage:"
echo "  nixos-rebuild switch --flake .#server --target-host ${SERVER_HOST} --impure"
echo "  ssh ${SERVER_HOST} sudo systemctl restart podman-homepage"

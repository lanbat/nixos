#!/usr/bin/env bash
# secrets/generate-secrets.sh
#
# Generates all purely-random secrets and stores them via agenix.
# Run this once from the repo root after creating secrets/secrets.nix.
#
# Usage:
#   cd /path/to/repo
#   bash secrets/generate-secrets.sh
#
# What this script does:
#   - Generates random values for all secrets that don't need external input.
#   - Skips secrets that require manual steps (OIDC client IDs, rclone config,
#     Telegraf token) and prints instructions for those instead.
#   - Never overwrites an existing .age file — safe to re-run.
#
# Secrets that still need manual input AFTER running this script:
#   secrets/mosquitto-ha-pass.age      — choose a password for the HA MQTT user
#   secrets/mosquitto-frigate-pass.age — choose a password for the Frigate MQTT user
#   secrets/rclone-frigate-config.age  — run: rclone config, then paste the result
#   secrets/telegraf-token.age         — fill in after deploying InfluxDB (step 3i)
#
# OIDC client secrets (Grafana, Nextcloud, Immich, HA, Jellyfin) are handled
# by a separate script once Authentik is running:
#   bash secrets/generate-oidc-secrets.sh

set -euo pipefail

cd "$(dirname "$0")"

AGENIX="agenix"
if ! command -v agenix &>/dev/null; then
  echo "ERROR: agenix not found. Install it first:"
  echo "  nix shell github:ryantm/agenix"
  exit 1
fi

if [ ! -f secrets.nix ]; then
  echo "ERROR: secrets/secrets.nix not found."
  echo "  cp secrets/secrets.nix.example secrets/secrets.nix"
  echo "  # then fill in your SSH public keys"
  exit 1
fi

rand() { openssl rand -base64 "$1"; }

encrypt() {
  local file="$1"
  local content="$2"
  if [ -f "$file" ]; then
    echo "  SKIP  $file (already exists)"
    return
  fi
  printf '%s' "$content" | $AGENIX -e "$file"
  echo "  OK    $file"
}

echo "Generating secrets..."
echo

# ---- Authentik ----
encrypt authentik-env.age \
  "AUTHENTIK_POSTGRESQL__PASSWORD=$(rand 36)
AUTHENTIK_SECRET_KEY=$(rand 50)"

# ---- Nextcloud ----
encrypt nextcloud-db-pass.age    "$(rand 36)"
encrypt nextcloud-admin-pass.age "$(rand 24)"

# ---- Immich ----
encrypt immich-db-password.age "POSTGRES_PASSWORD=$(rand 36)"

# ---- InfluxDB ----
encrypt influxdb-admin-password.age "$(rand 24)"
encrypt influxdb-admin-token.age    "$(rand 48)"

# ---- Grafana ----
# GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET is left blank — fill in after Phase 3b.
GRAFANA_SECRET_KEY="$(rand 48)"
GRAFANA_ADMIN_PASS="$(rand 24)"
encrypt grafana-env.age \
  "GF_SECURITY_SECRET_KEY=${GRAFANA_SECRET_KEY}
GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASS}
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=FILL_IN_AFTER_AUTHENTIK_SETUP
INFLUXDB_TOKEN=FILL_IN_SAME_AS_influxdb-admin-token.age"

# ---- Mosquitto ----
# Random passwords for each MQTT user.  The same value is used by both
# Mosquitto (passwordFile) and the connecting service (env var).
encrypt mosquitto-ha-pass.age      "$(rand 24)"
encrypt mosquitto-frigate-pass.age "$(rand 24)"
encrypt mosquitto-z2m-pass.age     "$(rand 24)"

# ---- Frigate ----
# Random RTSP credentials — set the same values in the camera's web UI.
encrypt frigate-rtsp-env.age \
  "FRIGATE_RTSP_USER=$(openssl rand -hex 8)
FRIGATE_RTSP_PASSWORD=$(rand 24)"

# ---- Vaultwarden ----
encrypt vaultwarden-env.age "ADMIN_TOKEN=$(rand 48)"

echo
echo "Done. Secrets that still need manual input:"
echo
echo "  secrets/rclone-frigate-config.age  — run 'rclone config' then paste the result:"
echo "    agenix -e secrets/rclone-frigate-config.age"
echo
echo "  secrets/telegraf-token.age         — fill in after deploying InfluxDB (step 3i):"
echo "    TELEGRAF_INFLUXDB_TOKEN=<value>"
echo "    agenix -e secrets/telegraf-token.age"
echo
echo "  secrets/grafana-env.age            — update INFLUXDB_TOKEN after step 3h:"
echo "    agenix -e secrets/grafana-env.age"
echo
echo "OIDC client secrets are handled separately once Authentik is running:"
echo "  bash secrets/generate-oidc-secrets.sh"
echo
echo "Commit the generated .age files:"
echo "  git add secrets/*.age && git commit -m 'add initial secrets'"

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
#   secrets/nextcloud-oidc-env.age   — fill in after creating Authentik OIDC app
#   secrets/immich-oidc-env.age      — fill in after creating Authentik OIDC app
#   secrets/grafana-env.age          — GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET needs Authentik
#   secrets/mosquitto-ha-pass.age    — choose a password for the HA MQTT user
#   secrets/mosquitto-frigate-pass.age — choose a password for the Frigate MQTT user
#   secrets/rclone-frigate-config.age — run: rclone config, then paste the result
#   secrets/telegraf-token.age       — fill in after deploying InfluxDB (step 3i)

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

# ---- Vaultwarden ----
encrypt vaultwarden-env.age "ADMIN_TOKEN=$(rand 48)"

echo
echo "Done. Secrets that still need manual input:"
echo
echo "  secrets/nextcloud-oidc-env.age     — after creating Authentik OIDC app (step 3b):"
echo "    NEXTCLOUD_OIDC_CLIENT_ID=<value>"
echo "    NEXTCLOUD_OIDC_CLIENT_SECRET=<value>"
echo
echo "  secrets/immich-oidc-env.age        — after creating Authentik OIDC app (step 3b):"
echo "    IMMICH_OAUTH_CLIENT_ID=<value>"
echo "    IMMICH_OAUTH_CLIENT_SECRET=<value>"
echo
echo "  secrets/grafana-env.age            — update GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"
echo "                                       and INFLUXDB_TOKEN after step 3b/3h."
echo "    agenix -e secrets/grafana-env.age"
echo
echo "  secrets/mosquitto-ha-pass.age      — choose a password for the HA MQTT user:"
echo "    agenix -e secrets/mosquitto-ha-pass.age"
echo
echo "  secrets/mosquitto-frigate-pass.age — choose a password for Frigate MQTT user:"
echo "    agenix -e secrets/mosquitto-frigate-pass.age"
echo
echo "  secrets/rclone-frigate-config.age  — run 'rclone config' then paste the result:"
echo "    agenix -e secrets/rclone-frigate-config.age"
echo
echo "  secrets/telegraf-token.age         — fill in after deploying InfluxDB (step 3i):"
echo "    TELEGRAF_INFLUXDB_TOKEN=<value>"
echo "    agenix -e secrets/telegraf-token.age"
echo
echo "Commit the generated .age files:"
echo "  git add secrets/*.age && git commit -m 'add initial secrets'"

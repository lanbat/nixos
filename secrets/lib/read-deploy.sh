#!/usr/bin/env bash
# secrets/lib/read-deploy.sh
#
# Read values from the active deployment configuration (deploy.nix manifest or
# a profile file under deployments/). Used by helper scripts that SSH to hosts.
#
# Usage: read-deploy.sh <key>
# Keys: server-ip, domain, profile, flake-server, immich-admin-email, hosts,
#       host-ips, deploy-file

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if result="$(nix run .#deploy-query -- "$1" 2>/dev/null)"; then
  echo "$result"
  exit 0
fi

# Fallback for environments where nix run fails (e.g. contributors without deploy).
DEPLOY_FILE="$ROOT/deployments/example/deploy.nix"
PROFILE="example"

case "${1:-}" in
  server-ip)
    awk '/server = \{/,/^\s*\};/ {
      if ($0 ~ /ip = /) { gsub(/.*ip = "|".*/, ""); print; exit }
    }' "$DEPLOY_FILE"
    ;;
  domain)
    sed -n 's/.*domain = "\([^"]*\)".*/\1/p' "$DEPLOY_FILE" | head -1
    ;;
  profile)
    echo "$PROFILE"
    ;;
  flake-server)
    echo "${PROFILE}-server"
    ;;
  immich-admin-email)
    sed -n 's/.*adminEmail = "\([^"]*\)".*/\1/p' "$DEPLOY_FILE" | head -1
    ;;
  deploy-file)
    echo "$DEPLOY_FILE"
    ;;
  hosts)
    awk '/server = \{/,/^\s*\};/ {
      if ($0 ~ /ip = /) { gsub(/.*ip = "|".*/, ""); print "example-server " $0; exit }
    }' "$DEPLOY_FILE"
    ;;
  host-ips)
    awk '/server = \{/,/^\s*\};/ {
      if ($0 ~ /ip = /) { gsub(/.*ip = "|".*/, ""); print; exit }
    }' "$DEPLOY_FILE"
    ;;
  *)
    echo "unknown key: ${1:-}" >&2
    exit 1
    ;;
esac

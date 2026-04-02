#!/usr/bin/env bash
# trust-ca-macos.sh
#
# Install the homelab internal CA on macOS.
# Run as a regular user with sudo available.
set -euo pipefail

CA_URL="https://ca.@DOMAIN@/root.crt"
CERT_FILE=/tmp/lanbat-ca.crt

echo "Downloading homelab CA (ignoring cert errors for initial download)..."
curl --insecure -fsSL "$CA_URL" -o "$CERT_FILE"

echo "Installing to System keychain (requires sudo)..."
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain "$CERT_FILE"

echo ""
echo "Done. The homelab CA is now trusted on this Mac."
echo "Restart Safari, Chrome, or Firefox if they were open."

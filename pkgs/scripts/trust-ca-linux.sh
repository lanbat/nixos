#!/usr/bin/env bash
# trust-ca-linux.sh
#
# Install the homelab internal CA on a Linux machine.
# Run as root.
set -euo pipefail

CA_URL="https://ca.@DOMAIN@/root.crt"
CERT_NAME="lanbat-ca"

echo "Downloading homelab CA from $CA_URL..."

# Try curl with --insecure for initial download (CA not trusted yet).
if command -v curl &>/dev/null; then
  curl --insecure -fsSL "$CA_URL" -o /tmp/${CERT_NAME}.crt
elif command -v wget &>/dev/null; then
  wget --no-check-certificate -qO /tmp/${CERT_NAME}.crt "$CA_URL"
else
  echo "ERROR: curl or wget required." >&2
  exit 1
fi

echo "Downloaded. Detecting distro..."

if [ -d /usr/local/share/ca-certificates ]; then
  # Debian / Ubuntu / NixOS (with updateCACertificates)
  cp /tmp/${CERT_NAME}.crt /usr/local/share/ca-certificates/${CERT_NAME}.crt
  update-ca-certificates
  echo "Installed via update-ca-certificates."

elif [ -d /etc/pki/ca-trust/source/anchors ]; then
  # Fedora / RHEL / AlmaLinux
  cp /tmp/${CERT_NAME}.crt /etc/pki/ca-trust/source/anchors/${CERT_NAME}.crt
  update-ca-trust
  echo "Installed via update-ca-trust."

elif [ -d /etc/ca-certificates/trust-source/anchors ]; then
  # Arch Linux
  cp /tmp/${CERT_NAME}.crt /etc/ca-certificates/trust-source/anchors/${CERT_NAME}.crt
  update-ca-trust
  echo "Installed via update-ca-trust (Arch)."

else
  echo "Unknown distro layout. Cert saved to /tmp/${CERT_NAME}.crt — install manually."
  exit 1
fi

# Also install for the current user's NSS database (Firefox, Chrome on Linux).
if [ -n "${SUDO_USER:-}" ]; then
  user_home=$(eval echo ~$SUDO_USER)
  for db in "$user_home/.pki/nssdb" "$user_home/snap/chromium/current/.pki/nssdb"; do
    if [ -d "$db" ]; then
      echo "Installing to NSS database: $db"
      certutil -A -d "sql:$db" -n "Lanbat Homelab CA" -t "CT,," \
        -i /tmp/${CERT_NAME}.crt 2>/dev/null || true
    fi
  done
fi

echo ""
echo "Done. The homelab CA is now trusted on this machine."
echo "Restart your browser if it was open."

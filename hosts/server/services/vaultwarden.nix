# hosts/server/services/vaultwarden.nix
#
# Vaultwarden — self-hosted Bitwarden-compatible password manager.
#
# Design
# ------
# - NixOS-native service (no container needed).
# - SQLite backend — simple and sufficient for a small homelab.
# - Listens on localhost:8222 (HTTP) and 3012 (WebSocket notifications).
# - Caddy terminates TLS and reverse-proxies both endpoints.
# - Admin panel is protected by the admin token secret (not Authentik
#   forward auth, because Bitwarden clients need unauthenticated API access
#   to /api, /identity, etc.).
# - Signups are disabled by default; invite users from the admin panel.
#
# Secrets
# -------
# vaultwarden-admin-token.age — plaintext bcrypt hash or random token used
#   to access /admin.  Generate with:
#     echo -n "yourpassword" | argon2 $(openssl rand -base64 32) -id -t 3 \
#       -m 65540 -p 4 | grep "Encoded:" | cut -d' ' -f2
#   Or for a simpler (less secure) approach, just use a random string and
#   Vaultwarden will accept it as-is (not hashed).
#
# State
# -----
# /var/lib/vaultwarden  — SQLite DB + attachments (back this up!)
#
# Always-on: yes.  No NFS dependency.
{ config, lib, ... }:

{
  services.vaultwarden = {
    enable = true;

    # State dir — NixOS creates /var/lib/vaultwarden automatically.
    # The service runs as the "vaultwarden" user (created by the module).

    config = {
      # Bind to localhost only; Caddy is the public-facing entry point.
      ROCKET_ADDRESS   = "127.0.0.1";
      ROCKET_PORT      = 8222;

      # WebSocket notifications (used by browser extensions for live sync).
      WEBSOCKET_ENABLED = true;
      WEBSOCKET_ADDRESS = "127.0.0.1";
      WEBSOCKET_PORT    = 3012;

      # Disable open signup — invite users from the admin panel.
      SIGNUPS_ALLOWED  = false;
      INVITATIONS_ALLOWED = true;

      # Public URL — must match what Caddy exposes.
      DOMAIN = "https://vault.${config.lanbat.domain}";

      # Log level: warn is quiet enough for daily use.
      LOG_LEVEL = "warn";

      # Send admin-panel token from the agenix secret (see environmentFile).
      # ADMIN_TOKEN is set via environmentFile below.
    };

    # Inject the admin token from an agenix-managed secret file.
    # The file must contain exactly one line:
    #   ADMIN_TOKEN=<token>
    environmentFile = config.age.secrets.vaultwarden-env.path;
  };

  # ---------------------------------------------------------------------------
  # Agenix secret
  # ---------------------------------------------------------------------------
  age.secrets.vaultwarden-env = {
    file  = ../../../secrets/vaultwarden-env.age;
    owner = "vaultwarden";
  };
}

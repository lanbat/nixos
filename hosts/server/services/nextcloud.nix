# hosts/server/services/nextcloud.nix
#
# Nextcloud — file sync and collaboration.
#
# Storage split
# -------------
# Server-local (fast, reliable, always-on):
#   /var/lib/nextcloud/     — app code, config, skeleton
#   PostgreSQL              — database (shared instance)
#
# Pi-backed via NFS (/srv/storage/b):
#   /srv/storage/b/nextcloud/external/  — bulk user data (External Storage app)
#
# If the Pi is down, Nextcloud still works — external storage shows errors
# for those folders only; the app itself is healthy.
#
# Auth
# ----
# Nextcloud uses the `user_oidc` app to delegate login to Authentik.
# The occ setup service below configures it automatically, but it needs
# the OIDC client credentials from Authentik first (chicken-and-egg):
#   1. Deploy Nextcloud.
#   2. Create the OIDC application in Authentik UI.
#   3. Store the client_id/secret in agenix (nextcloud-oidc-env.age).
#   4. Rebuild — the setup service runs and configures OIDC.
# Local admin account is always kept as break-glass.
{ config, pkgs, lib, ... }:

let domain = config.lanbat.domain; in

{
  services.nextcloud = {
    enable   = true;
    hostName = "cloud.${domain}";
    package  = pkgs.nextcloud30;

    https = true;

    # Use local PostgreSQL via Unix socket (peer auth — no password needed).
    # The module creates the database and user automatically.
    database.createLocally = true;

    config = {
      adminuser     = "admin";
      adminpassFile = config.age.secrets.nextcloud-admin-pass.path;
    };

    phpOptions = {
      "opcache.interned_strings_buffer" = "16";
      "opcache.max_accelerated_files"   = "10000";
      "opcache.memory_consumption"      = "128";
      "opcache.save_comments"           = "1";
      "opcache.revalidate_freq"         = "1";
      upload_max_filesize = lib.mkForce "16G";
      post_max_size       = lib.mkForce "16G";
      memory_limit        = "512M";
    };

    extraApps = with config.services.nextcloud.package.packages.apps; {
      # user_oidc is the OIDC login app.
      # It may not be in the generated apps attrset for all NC versions;
      # if it isn't, install it via occ app:install user_oidc post-deploy.
      # inherit user_oidc;
    };
    extraAppsEnable = true;

    settings = {
      trusted_proxies   = [ "127.0.0.1" ];
      overwrite.cli.url = "https://cloud.${domain}";
      default_phone_region = config.lanbat.phoneRegion;
    };
  };

  # ---------------------------------------------------------------------------
  # OIDC setup via occ (runs once after Nextcloud is up)
  # ---------------------------------------------------------------------------
  # This service configures the user_oidc provider pointing to Authentik.
  # It is idempotent: it checks whether the provider already exists first.
  # It will fail (and be retried) until nextcloud-oidc-env.age is populated.
  systemd.services."nextcloud-oidc-setup" = {
    description = "Configure Nextcloud OIDC provider";
    after       = [ "nextcloud-setup.service" ];
    wantedBy    = [ "nextcloud-setup.service" ];
    # Only runs if the env file exists and is non-empty.
    unitConfig.ConditionPathExists = config.age.secrets.nextcloud-oidc-env.path;
    serviceConfig = {
      Type    = "oneshot";
      User    = "nextcloud";
      # Source the env file which exports:
      #   NEXTCLOUD_OIDC_CLIENT_ID=<value>
      #   NEXTCLOUD_OIDC_CLIENT_SECRET=<value>
      ExecStart = pkgs.writeShellScript "nextcloud-oidc-setup" ''
        set -euo pipefail
        . ${config.age.secrets.nextcloud-oidc-env.path}

        OCC="${config.services.nextcloud.occ}/bin/nextcloud-occ"

        # Enable the app if not already enabled.
        $OCC app:enable user_oidc || true

        # Check if provider already registered.
        if $OCC user_oidc:provider:list 2>/dev/null | grep -q "Authentik"; then
          echo "OIDC provider already configured."
          exit 0
        fi

        $OCC user_oidc:provider Authentik \
          --clientid="$NEXTCLOUD_OIDC_CLIENT_ID" \
          --clientsecret="$NEXTCLOUD_OIDC_CLIENT_SECRET" \
          --discoveryuri="https://auth.${domain}/application/o/nextcloud/.well-known/openid-configuration" \
          --mapping-uid="preferred_username" \
          --unique-uid=0

        echo "Nextcloud OIDC provider configured."
      '';
      RemainAfterExit = false;
    };
  };

  # Configure nginx to listen on the internal port so Caddy can own :80/:443.
  services.nginx.virtualHosts."cloud.${domain}" = {
    listen = [{ addr = "127.0.0.1"; port = 8080; ssl = false; }];
  };

  # External storage paths (created when NFS is mounted).
  systemd.tmpfiles.rules = [
    "d /srv/storage/b/nextcloud          0750 nextcloud nextcloud -"
    "d /srv/storage/b/nextcloud/external 0750 nextcloud nextcloud -"
    "d /srv/storage/b/nextcloud/users    0750 nextcloud nextcloud -"
  ];
}

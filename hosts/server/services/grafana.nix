# hosts/server/services/grafana.nix
#
# Grafana — metrics dashboards and alerting.
#
# Design
# ------
# - NixOS-native service; no container needed.
# - Listens on localhost:3030 (port 3000 is taken by Homepage).
# - Caddy terminates TLS and proxies grafana.<domain>.
# - Auth: Authentik OIDC via generic_oauth.  Local admin is kept as
#   break-glass.  Auto-assign the Viewer role to all Authentik users;
#   promote individuals to Editor/Admin in the Grafana UI as needed.
# - InfluxDB datasource is provisioned declaratively — no manual setup
#   required after deploy.
#
# Secrets (all in grafana-env.age, one KEY=value per line)
# -------
#   GF_SECURITY_SECRET_KEY          — random 64-char string for session signing
#   GF_SECURITY_ADMIN_PASSWORD      — local break-glass admin password
#   GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET — OIDC client secret from Authentik
#   INFLUXDB_TOKEN                  — same operator token as influxdb-admin-token.age
#
# OIDC setup (chicken-and-egg, same pattern as Nextcloud/Immich)
# -----
#   1. Deploy Grafana (OIDC settings reference env vars that are empty → login
#      falls back to local admin).
#   2. Create an OIDC application in Authentik for Grafana.
#      Redirect URI: https://grafana.<domain>/login/generic_oauth
#   3. Populate grafana-env.age with the client secret.
#   4. Rebuild — OIDC login becomes available.
#
# Always-on: yes.  No NFS dependency.
{ config, ... }:

let domain = config.lanbat.domain; in

{
  services.grafana = {
    enable = true;

    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = 3030;
        domain    = "grafana.${domain}";
        root_url  = "https://grafana.${domain}";
      };

      security = {
        # Injected at runtime from grafana-env.age — never written to store.
        secret_key      = "$__env{GF_SECURITY_SECRET_KEY}";
        admin_password  = "$__env{GF_SECURITY_ADMIN_PASSWORD}";
        admin_user      = "admin";
      };

      # ---------------------------------------------------------------------------
      # Authentik OIDC
      # ---------------------------------------------------------------------------
      "auth.generic_oauth" = {
        enabled               = true;
        name                  = "Authentik";
        allow_sign_up         = true;
        # Client ID is not a secret — set it here directly.
        # CHANGE_ME: replace with the client ID from the Authentik application.
        client_id             = "CHANGE_ME_GRAFANA_OIDC_CLIENT_ID";
        client_secret         = "$__env{GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET}";
        scopes                = "openid email profile";
        auth_url              = "https://auth.${domain}/application/o/authorize/";
        token_url             = "https://auth.${domain}/application/o/token/";
        api_url               = "https://auth.${domain}/application/o/userinfo/";
        # Map all Authentik users to Viewer by default; promote in Grafana UI.
        role_attribute_path   = "contains(groups, 'grafana-admins') && 'Admin' || 'Viewer'";
        login_attribute_path  = "preferred_username";
        name_attribute_path   = "name";
        email_attribute_path  = "email";
        use_pkce              = true;
      };
    };

    # ---------------------------------------------------------------------------
    # Declarative datasource provisioning
    # ---------------------------------------------------------------------------
    provision = {
      enable = true;

      datasources.settings.datasources = [
        {
          name      = "InfluxDB";
          type      = "influxdb";
          access    = "proxy";
          url       = "http://127.0.0.1:8086";
          isDefault = true;

          jsonData = {
            version      = "Flux";
            organization = "homelab";
            defaultBucket = "metrics";
            tlsSkipVerify = false;
          };

          # Token injected from the environment — not stored in Nix store.
          secureJsonData = {
            token = "$__env{INFLUXDB_TOKEN}";
          };
        }
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # Inject secrets at runtime
  # ---------------------------------------------------------------------------
  systemd.services.grafana.serviceConfig.EnvironmentFiles = [
    config.age.secrets.grafana-env.path
  ];

  # ---------------------------------------------------------------------------
  # Agenix secret
  # ---------------------------------------------------------------------------
  age.secrets.grafana-env = {
    file  = ../../../secrets/grafana-env.age;
    owner = "grafana";
  };
}

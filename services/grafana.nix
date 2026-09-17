# services/grafana.nix
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
# - InfluxDB datasource and Homelab dashboards are provisioned declaratively.
#
# Secrets (all in grafana-env.age, one KEY=value per line)
# -------
#   GF_SECURITY_SECRET_KEY          — random 64-char string for session signing
#   GF_SECURITY_ADMIN_PASSWORD      — local break-glass admin password
#   GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET — OIDC client secret from Authentik
#   INFLUXDB_TOKEN is injected at service start from influxdb-admin-token.age.
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
{ config, pkgs, ... }:

let
  domain = config.lanbat.deployment.domain;
  dashboards = pkgs.callPackage ../pkgs/grafana-dashboards { };
in

{
  lanbat.services.grafana = {
    subdomain = "grafana";
    port = 3030;
    secrets.grafana-env = { };
    dashboard = {
      group = "Monitoring";
      name = "Grafana";
      description = "Metrics dashboards";
      widget = {
        type = "grafana";
        version = 2;
        username = "admin";
        password = {
          _secret = {
            file = "grafana-env";
            var = "GF_SECURITY_ADMIN_PASSWORD";
          };
        };
      };
    };
  };

  # Dashboards, users and alert state live in the always-on PostgreSQL. Grafana
  # logs in as its system user over the socket, so no password is needed.
  lanbat.postgresql.databases.grafana.instance = "always-on";

  systemd.services.grafana-influxdb-token = {
    description = "InfluxDB operator token for Grafana datasource";
    before = [ "grafana.service" ];
    requiredBy = [ "grafana.service" ];
    # Use a separate runtime dir from grafana.service — stopping Grafana clears
    # its own RuntimeDirectory=grafana and would delete a shared token file.
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "grafana-datasource";
      RuntimeDirectoryMode = "0750";
    };
    script = ''
      umask 077
      echo "INFLUXDB_TOKEN=$(cat ${config.age.secrets.influxdb-admin-token.path})" \
        > /run/grafana-datasource/influxdb-token.env
      test -s /run/grafana-datasource/influxdb-token.env
    '';
  };

  systemd.services.grafana = {
    after = [
      config.lanbat.postgresql.instances.always-on.unit
      "grafana-influxdb-token.service"
    ];
    requires = [
      config.lanbat.postgresql.instances.always-on.unit
      "grafana-influxdb-token.service"
    ];
    serviceConfig = {
      # OAuth token/userinfo calls hit https://auth.<domain> server-side; trust
      # the internal Caddy CA (global environment.variables do not reach units).
      Environment = [
        "SSL_CERT_FILE=/var/lib/caddy-local-ca/ca-certificates.crt"
      ];
      EnvironmentFile = [
        config.age.secrets.grafana-env.path
        "/run/grafana-datasource/influxdb-token.env"
      ];
    };
  };

  services.grafana = {
    enable = true;

    settings = {
      database =
        let
          pg = config.lanbat.postgresql.instances.always-on;
        in
        {
          type = "postgres";
          # A socket directory with the port, which selects the socket file.
          host = "${pg.socket}:${toString pg.port}";
          name = "grafana";
          user = "grafana";
        };

      server = {
        http_addr = "127.0.0.1";
        http_port = config.lanbat.services.grafana.port;
        domain = "grafana.${domain}";
        root_url = "https://grafana.${domain}";
      };

      dashboards.default_home_dashboard_uid = "homelab-overview";

      users = {
        default_theme = "system";
        viewers_can_edit = false;
      };

      security = {
        # Injected at runtime from grafana-env.age — never written to store.
        secret_key = "$__env{GF_SECURITY_SECRET_KEY}";
        admin_password = "$__env{GF_SECURITY_ADMIN_PASSWORD}";
        admin_user = "admin";
      };

      auth.signout_redirect_url = "https://auth.${domain}/application/o/grafana/end-session/";

      # ---------------------------------------------------------------------------
      # Authentik OIDC
      # ---------------------------------------------------------------------------
      "auth.generic_oauth" = {
        enabled = true;
        name = "Authentik";
        allow_sign_up = true;
        # Client ID is not a secret — set it here directly.
        # CHANGE_ME: replace with the client ID from the Authentik application.
        client_id = "grafana";
        client_secret = "$__env{GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET}";
        scopes = "openid email profile";
        auth_url = "https://auth.${domain}/application/o/authorize/";
        token_url = "https://auth.${domain}/application/o/token/";
        api_url = "https://auth.${domain}/application/o/userinfo/";
        # Map all Authentik users to Viewer by default; promote in Grafana UI.
        role_attribute_path = "contains(groups[*], 'grafana-admins') && 'Admin' || 'Viewer'";
        login_attribute_path = "preferred_username";
        name_attribute_path = "name";
        email_attribute_path = "email";
        use_pkce = true;
      };
    };

    # ---------------------------------------------------------------------------
    # Declarative datasource provisioning
    # ---------------------------------------------------------------------------
    provision = {
      enable = true;

      datasources.settings = {
        # Replace the auto-generated UID from first boot with a stable one used
        # by the provisioned dashboards.
        deleteDatasources = [
          {
            name = "InfluxDB";
            orgId = 1;
          }
        ];

        datasources = [
          {
            name = "InfluxDB";
            uid = "influxdb-homelab";
            type = "influxdb";
            access = "proxy";
            url = "http://localhost:8086";
            isDefault = true;
            editable = false;

            jsonData = {
              version = "Flux";
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

      dashboards.settings = {
        apiVersion = 1;
        providers = [
          {
            name = "homelab";
            orgId = 1;
            folder = "Homelab";
            type = "file";
            disableDeletion = true;
            allowUiUpdates = false;
            updateIntervalSeconds = 30;
            options.path = dashboards;
          }
        ];
      };
    };
  };

}

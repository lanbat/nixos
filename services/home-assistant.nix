# services/home-assistant.nix
#
# Home Assistant — home automation hub.
#
# Why the NixOS module and not a container?
#   The NixOS `services.home-assistant` module handles component packaging,
#   config dir, user/group, and service lifecycle very cleanly.
#   It is significantly easier to maintain than a container for HA specifically
#   because NixOS can manage the Python component set declaratively.
#
# Zigbee
# ------
# Zigbee devices are bridged via Zigbee2MQTT (see zigbee2mqtt.nix).
# Z2M owns the USB dongle and publishes to Mosquitto; HA discovers devices
# via MQTT auto-discovery.  Do NOT add ZHA here — it would conflict with Z2M.
#
# Auth with Authentik
# -------------------
# Browser access is gated by Caddy forward-auth (Authentik session).  The
# hass-auth-header custom component maps X-Authentik-Username to an existing HA
# user, so entitled Authentik users land in HA without a second login.
#
# Companion apps and REST clients bypass forward-auth on /auth/token and /api/*
# and authenticate with HA long-lived tokens as usual.
#
# First-run onboarding is completed automatically by home-assistant-bootstrap
# (owner account + SSO user mirror).  Break-glass local login remains available
# on localhost.
#
# Always-on: yes — HA should survive Pi NFS loss.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  domain = config.lanbat.domain;
  authHeaderComponent = pkgs.callPackage ../pkgs/home-assistant-auth-header { };
  bootstrap = pkgs.callPackage ../pkgs/home-assistant-bootstrap { };
in
{
  options.lanbat.homeAssistant = {
    ssoUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "akadmin" ];
      description = ''
        Authentik usernames to provision as Home Assistant users.  Login is via
        header auth (no password); usernames must match Authentik exactly.
      '';
    };
  };

  config = {
    lanbat.services.home-assistant = {
      subdomain = "ha";
      port = 8123;
      auth = "forward-auth";
      apiClients = true; # companion apps — /auth/token and /api/* bypass forward-auth
      secrets.hass-bootstrap-env = {
        owner = "hass";
      };
      caddy.proxyOptions = ''
        # Long-lived websockets for HA's live updates.
        transport http {
          keepalive 24h
        }
      '';
      dashboard = {
        group = "Automation";
        name = "Home Assistant";
        description = "Home automation";
        widget = {
          type = "homeassistant";
          key = "CHANGE_ME_HA_LONG_LIVED_TOKEN";
        };
      };
    };

    # The recorder (history) lives in the always-on PostgreSQL. HA logs in as
    # its system user over the socket, so no password is needed.
    lanbat.postgresql.databases.hass.instance = "always-on";

    systemd.services.home-assistant = {
      after = [ config.lanbat.postgresql.instances.always-on.unit ];
      requires = [ config.lanbat.postgresql.instances.always-on.unit ];
    };

    systemd.services.home-assistant-bootstrap = {
      description = "Complete Home Assistant onboarding and provision SSO users";
      wantedBy = [ "multi-user.target" ];
      after = [ "home-assistant.service" ];
      wants = [ "home-assistant.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "hass";
        Group = "hass";
        EnvironmentFile = config.age.secrets.hass-bootstrap-env.path;
      };

      path = [ bootstrap ];

      script = ''
        set -a
        . ${config.age.secrets.hass-bootstrap-env.path}
        set +a
        export INTERNAL_URL="http://127.0.0.1:8123"
        export EXTERNAL_URL="https://ha.${domain}"
        export SSO_USERS="${lib.concatStringsSep " " config.lanbat.homeAssistant.ssoUsers}"
        exec home-assistant-bootstrap
      '';
    };

    services.home-assistant = {
      enable = true;
      openFirewall = false; # Caddy handles exposure.

      # PostgreSQL driver for the recorder.
      extraPackages = ps: [ ps.psycopg2 ];

      # Install extra Python components declaratively.
      customComponents = [
        # 2 upstream test failures in nixpkgs 26.05 packaging; skip checks.
        (pkgs.home-assistant-custom-components.frigate.overridePythonAttrs (_: {
          doCheck = false;
        }))
        (authHeaderComponent.overridePythonAttrs (_: {
          doCheck = false;
        }))
      ];

      extraComponents = [
        "default_config"
        "met" # weather
        "radio_browser"
        "google_translate" # TTS — gtts dependency
        "mqtt" # Zigbee devices arrive via Zigbee2MQTT → MQTT discovery
        "mobile_app"
        "person"
        "history"
        "logbook"
        "recorder"
        "frontend"
        "config"
        "lovelace"
        "network"
        "stream"
        "camera"
        "ffmpeg"
        # Wyoming voice assistant protocol
        "wyoming"
        "music_assistant"
        "qbittorrent"
      ];

      config = {
        # Trust Caddy as reverse proxy.
        http = {
          use_x_forwarded_for = true;
          trusted_proxies = [
            "127.0.0.1"
            "::1"
          ];
          ip_ban_enabled = true;
          login_attempts_threshold = 5;
        };

        homeassistant = {
          name = "Home";
          latitude = config.lanbat.haLatitude;
          longitude = config.lanbat.haLongitude;
          elevation = config.lanbat.haElevation;
          unit_system = "metric";
          time_zone = config.lanbat.timezone;
          external_url = "https://ha.${domain}";
        };

        # Authentik forward-auth → header-based login (users must exist in HA).
        auth_header = {
          username_header = "X-Authentik-Username";
        };

        # Recorder — keep 30 days in the always-on PostgreSQL.
        recorder = {
          purge_keep_days = 30;
          db_url =
            let
              pg = config.lanbat.postgresql.instances.always-on;
            in
            "postgresql://@/hass?host=${pg.socket}&port=${toString pg.port}";
        };
      };
    };

    # HA state lives entirely on server-local storage — resilient to Pi loss.
    # /var/lib/hass is managed by the NixOS module.
  };
}

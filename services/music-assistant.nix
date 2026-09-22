# services/music-assistant.nix
#
# Music Assistant — music library controller and multi-room orchestrator.
#
# Why the NixOS module and not a container?
#   `services.music-assistant` exists in pinned nixpkgs (2.7.x) and runs as a
#   native systemd service on the host network stack — no rootless Podman
#   multicast caveats.  CONTRIBUTING.md prefers native modules when available.
#
# Snapcast integration (distribution layer)
# -----------------------------------------
# Snapcast stays declarative in services/snapcast.nix (snapserver on 1704/1705).
# Music Assistant does NOT write to the old FIFO.  When the Snapcast player
# provider is enabled in the MA UI with "Use existing Snapserver", MA connects
# to snapserver's control API (port 1705) and creates per-playback TCP streams
# dynamically via stream_add_stream — see music_assistant/providers/snapcast/
# player.py::_get_or_create_stream in the nixpkgs package source.
#
# Post-deploy: Settings → Player Providers → Snapcast → enable "Use existing
# Snapserver", host 127.0.0.1, control port 1705.  Do NOT use MA's built-in
# snapserver (it would bind the same ports).
#
# Local music library
# -------------------
# The filesystem_local provider reads /srv/storage/b/media/music over NFS.
# That path is Pi-backed (automount, not workload-gated).  MA is always-on:
# we deliberately avoid lanbat.services.*.nfs.drives (which would stop MA when
# the Pi disappears).  The service starts without the mount; library scans fail
# gracefully until NFS is available.
#
# Auth with Home Assistant
# ----------------------
# Browser access to music.<domain> is gated by Caddy forward-auth (Authentik).
# Music Assistant has no Authentik header passthrough like Home Assistant, so
# users sign in via "Login with Home Assistant" (HA OAuth) after Authentik.
# music-assistant-setup provisions the hass plugin, base URL, self-registration,
# and the bidirectional long-lived tokens for the HA integration.
#
# Always-on: yes.  State in /var/lib/music-assistant (provider config, playlists).
{
  config,
  pkgs,
  lib,
  ...
}:

let
  musicLibrary = "/srv/storage/b/media/music";
  domain = config.lanbat.deployment.domain;
  setup = pkgs.callPackage ../pkgs/music-assistant-setup {
    inherit pkgs;
  };

  # The setup step registers Music Assistant with Home Assistant and configures
  # OAuth login against it. Without Home Assistant there is nothing to register
  # with, and Music Assistant still plays music.
  integrates = config.lanbat.hasService "home-assistant";
in
{
  lanbat.services.music-assistant = {
    subdomain = "music";
    port = 8095;
    extraPorts = [
      8097 # MA stream server (players / imageproxy)
    ];
    auth = "forward-auth";
    consumes = lib.optional integrates "home-assistant";
    # The web UI probes /info and opens /ws before Music Assistant's own login.
    # Static assets and API paths must also bypass Authentik or the SPA shows
    # "Connect" / "Connection Lost" after the shell page loads.
    caddy.authBypassPaths = [
      "/info"
      "/ws"
      "/setup"
      "/auth/*"
      "/api"
      "/api/*"
      "/assets/*"
      "/resources/*"
      "/favicon.ico"
      "/manifest.json"
      "/logo.png"
      "/sw.js"
      "/workbox-*"
    ];
    caddy.proxyOptions = ''
      transport http {
        keepalive 24h
      }
    '';
    account = {
      uid = 964;
      extraGroups = [ "media" ];
    };
    dashboard = {
      group = "Media";
      name = "Music Assistant";
      description = "Multi-room music controller";
    };
  };

  services.music-assistant = {
    enable = true;
    openFirewall = false; # Caddy handles the web UI; 8095 stays closed on the firewall.
    providers = [
      "snapcast"
      "filesystem_local"
    ];
  };

  # Upstream uses DynamicUser; override to a pinned account in the media group
  # so filesystem_local can read NFS-mounted tracks (0750, group media).
  systemd.services.music-assistant = {
    after = [
      "network-online.target"
      "snapserver.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "music-assistant";
      Group = "music-assistant";
      SupplementaryGroups = [ "media" ];
      # HA OAuth token exchange calls https://ha.<domain> server-side; trust the
      # internal Caddy CA (global environment.variables do not reach systemd units).
      Environment = [
        "SSL_CERT_FILE=/var/lib/caddy-local-ca/ca-certificates.crt"
        "REQUESTS_CA_BUNDLE=/var/lib/caddy-local-ca/ca-certificates.crt"
      ];
      # Do not bind the NFS library path here — systemd fails to start when
      # the Pi automount is not yet available.  Scans fail gracefully instead.
    };
  };

  systemd.services.music-assistant-setup = lib.mkIf integrates {
    description = "Configure Music Assistant Home Assistant integration and OAuth login";
    wantedBy = [ "multi-user.target" ];
    after = [
      "music-assistant.service"
      "home-assistant.service"
      "home-assistant-bootstrap.service"
    ];
    wants = [
      "music-assistant.service"
      "home-assistant.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    path = with pkgs; [
      setup
      sudo
      config.services.home-assistant.package
    ];

    script = ''
      set -a
      . ${config.age.secrets.hass-bootstrap-env.path}
      set +a
      export MA_URL="http://127.0.0.1:8095"
      export MA_PUBLIC_URL="https://music.${domain}"
      export HA_INTERNAL_URL="http://127.0.0.1:8123"
      export HA_PUBLIC_URL="https://ha.${domain}"
      export HASS_BIN="${config.services.home-assistant.package}/bin/hass"
      export HASS_CONFIG="/var/lib/hass"
      # Music Assistant's Snapcast players come from the snapserver (services/snapcast.nix).
      export SNAPSERVER_CONTROL_PORT="${toString config.services.snapserver.settings.tcp-control.port}"
      exec music-assistant-setup
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/music-assistant/.lanbat-setup 0700 music-assistant music-assistant -"
  ];
}

# services/jellyfin.nix
#
# Jellyfin media server.
#
# Why the NixOS module?
#   `services.jellyfin` is well-maintained, handles the user/group, config
#   dir, and service lifecycle cleanly.  No reason to containerize.
#
# Storage split
# -------------
# Server-local:
#   /var/lib/jellyfin/            — config, database, metadata, posters
#   /var/cache/jellyfin/          — transcodes (safe to delete at any time)
#
# Pi-backed via NFS, media split across both drives by folder:
#   /srv/storage/a/media/         — movies, TV, music videos
#   /srv/storage/b/media/         — music, documentaries, books, etc.
#   /srv/storage/b/media/adult/   — private group only; excluded from Jellyfin
#
# NFS dependency: strong.
#   Jellyfin should not run if Pi storage is unavailable — it would
#   write error states into its database and display a broken library.
#   We declare a hard BindsTo dependency so systemd stops Jellyfin when
#   the mount disappears and restarts it when the mount returns.
#
# Discovery
# ---------
# TV and mobile apps find the server via UDP broadcast on port 7359 (not mDNS).
# Caddy serves HTTPS on 443; discovery must advertise that URL so clients do
# not fall back to the blocked local HTTP port 8096.
#
# First-run onboarding, media libraries, plugins, and Authentik SSO are
# completed automatically by jellyfin-bootstrap.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  domain = config.lanbat.domain;
  bootstrap = pkgs.callPackage ../pkgs/jellyfin-bootstrap { };
in
{
  lanbat.services.jellyfin = {
    subdomain = "media";
    port = 8096;
    extraPorts = [ 7359 ]; # UDP auto-discovery for TV and mobile apps
    apiClients = true; # TV and mobile apps
    tier = "workload";
    state = [ "jellyfin" ];
    units = [
      "jellyfin"
      "jellyfin-bootstrap"
    ];
    workloadDirs."jellyfin".user = "jellyfin";
    nfs.drives = [
      "a"
      "b"
    ];
    account = {
      uid = 992;
      extraGroups = [ "media" ];
    };
    dashboard = {
      group = "Media";
      name = "Jellyfin";
      description = "Media server";
      widget = {
        type = "jellyfin";
        key = {
          _secret = "JELLYFIN_API_KEY";
        };
      };
    };
  };

  services.jellyfin = {
    enable = true;
    openFirewall = false; # Caddy handles exposure.
  };

  systemd.tmpfiles.rules = [
    "d /var/cache/jellyfin    0750 jellyfin jellyfin -"
  ];

  systemd.services.jellyfin = {
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "15s";
      Environment = [
        "JELLYFIN_PublishedServerUrl=https://media.${domain}"
      ];
    };
  };

  networking.firewall.allowedUDPPorts = [ 7359 ];

  systemd.services.jellyfin-bootstrap = {
    description = "Complete Jellyfin setup (wizard, libraries, plugins, SSO)";
    wantedBy = [ "multi-user.target" ];
    after = [ "jellyfin.service" ];
    wants = [ "jellyfin.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      Restart = "on-failure";
      RestartSec = "30s";
    };

    path = [ bootstrap ];

    script = ''
      set -a
      . ${config.age.secrets.hass-bootstrap-env.path}
      . ${config.age.secrets.authentik-oidc-secrets.path}
      set +a
      export JELLYFIN_URL="http://127.0.0.1:8096"
      export EXTERNAL_URL="https://media.${domain}"
      export AUTH_DOMAIN="${domain}"
      exec jellyfin-bootstrap
    '';
  };
}

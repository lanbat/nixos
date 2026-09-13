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
#   /srv/storage/b/media/         — music, documentaries, books and the rest
# Add the folders of both drives to the libraries. The Pi creates them
# (modules/pi/storage.nix), owned by qbt, group media; Jellyfin reads them
# through its media group.
#
# NFS dependency: strong.
#   Jellyfin should not run if Pi storage is unavailable — it would
#   write error states into its database and display a broken library.
#   We declare a hard BindsTo dependency so systemd stops Jellyfin when
#   the mount disappears and restarts it when the mount returns.
#
# First-run onboarding is completed automatically by jellyfin-bootstrap
# (admin account from hass-bootstrap-env.age).  SSO plugin setup remains manual.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  bootstrap = pkgs.callPackage ../pkgs/jellyfin-bootstrap { };
in
{
  lanbat.services.jellyfin = {
    subdomain = "media";
    port = 8096;
    apiClients = true; # TV and mobile apps
    tier = "workload";
    state = [ "jellyfin" ];
    units = [
      "jellyfin"
      "jellyfin-bootstrap"
    ];
    # Created for jellyfin on the workload layer; root-owned, Jellyfin can't
    # write its data and aborts on start.
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
        key = "CHANGE_ME_JELLYFIN_API_KEY";
      };
    };
  };

  services.jellyfin = {
    enable = true;
    openFirewall = false; # Caddy handles exposure.
  };

  # Transcode dir — put on local fast storage, not NFS.
  # Set JellyfinFFmpegTranscodingPath in the admin UI or via config below.
  systemd.tmpfiles.rules = [
    "d /var/cache/jellyfin    0750 jellyfin jellyfin -"
  ];

  # Restart on failure so it comes back when NFS is restored.
  systemd.services.jellyfin = {
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "15s";
    };
  };

  systemd.services.jellyfin-bootstrap = {
    description = "Complete Jellyfin first-run startup wizard";
    wantedBy = [ "multi-user.target" ];
    after = [ "jellyfin.service" ];
    wants = [ "jellyfin.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    path = [ bootstrap ];

    script = ''
      set -a
      . ${config.age.secrets.hass-bootstrap-env.path}
      set +a
      export JELLYFIN_URL="http://127.0.0.1:8096"
      exec jellyfin-bootstrap
    '';
  };
}

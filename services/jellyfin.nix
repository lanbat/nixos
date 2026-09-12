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
{
  config,
  pkgs,
  lib,
  ...
}:

{
  lanbat.services.jellyfin = {
    subdomain = "media";
    port = 8096;
    apiClients = true; # TV and mobile apps
    tier = "workload";
    state = [ "jellyfin" ];
    units = [ "jellyfin" ];
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
}

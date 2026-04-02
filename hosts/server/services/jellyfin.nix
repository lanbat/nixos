# hosts/server/services/jellyfin.nix
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
# Pi-backed via NFS (/srv/storage/a):
#   /srv/storage/a/media/         — all media libraries (movies, TV, music)
#
# NFS dependency: strong.
#   Jellyfin should not run if /srv/storage/a is unavailable — it would
#   write error states into its database and display a broken library.
#   We declare a hard BindsTo dependency so systemd stops Jellyfin when
#   the mount disappears and restarts it when the mount returns.
{ config, pkgs, lib, ... }:

{
  services.jellyfin = {
    enable     = true;
    openFirewall = false; # Caddy handles exposure.

    # User/group — jellyfin user is created by the module; we added
    # it to the "media" group in modules/common/users.nix.
  };

  # Transcode dir — put on local fast storage, not NFS.
  # Set JellyfinFFmpegTranscodingPath in the admin UI or via config below.
  systemd.tmpfiles.rules = [
    "d /var/cache/jellyfin    0750 jellyfin jellyfin -"
    "d /srv/storage/a/media   0750 jellyfin media    -"
    "d /srv/storage/a/media/movies  0750 jellyfin media -"
    "d /srv/storage/a/media/tv      0750 jellyfin media -"
    "d /srv/storage/a/media/music   0750 jellyfin media -"
  ];

  # ---------------------------------------------------------------------------
  # NFS dependency — stop Jellyfin when Pi storage is gone.
  # ---------------------------------------------------------------------------
  lanbat.nfsDependentServices."jellyfin" = [ "a" ];

  # Restart on failure so it comes back when NFS is restored.
  systemd.services.jellyfin = {
    serviceConfig = {
      Restart    = "on-failure";
      RestartSec = "15s";
    };
  };
}

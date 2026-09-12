# services/qbittorrent.nix
#
# qBittorrent — torrent client with web UI.
#
# Storage split
# -------------
# Server-local:
#   /var/lib/qbittorrent/   — qBittorrent config, fastresume files, session state
#
# Pi-backed via NFS, media split across both drives by folder:
#   /srv/storage/a/media/  → /media/a  (movies, TV, music videos)
#   /srv/storage/b/media/  → /media/b  (music, documentaries, ROMs, books, ...)
# Each category saves into its folder. The Pi creates the folders
# (modules/pi/storage.nix), owned by qbt, group media.
#
# NFS dependency: strong.
#   If Pi storage disappears while a torrent is active, qBittorrent will
#   write I/O errors.  We stop it immediately and restart when NFS returns.
#
# Auth: qBittorrent web UI has its own session auth.
#   The web UI is behind Caddy's Authentik forward_auth, so users must log
#   into Authentik first.  qBittorrent's own auth acts as a second factor
#   for direct API access; the web password is set via admin UI on first run.
#   Keep qBittorrent local auth enabled — do not disable it.
#
# One shared instance is enough.
{
  config,
  pkgs,
  lib,
  ...
}:

{
  lanbat.services.qbittorrent = {
    subdomain = "torrent";
    port = 8090;
    auth = "forward-auth";
    tier = "workload";
    state = [ "qbittorrent" ];
    units = [ "podman-qbittorrent" ];
    workloadDirs."qbittorrent".user = "qbt";
    nfs.drives = [
      "a"
      "b"
    ];
    account = {
      name = "qbt";
      uid = 994;
      container = true;
      extraGroups = [ "media" ];
    };
    dashboard = {
      group = "Downloads";
      name = "qBittorrent";
      description = "Torrent client";
    };
  };

  # Run qBittorrent as an OCI container to simplify volume mounts and
  # to use the linuxserver.io image which ships a clean web UI.
  virtualisation.oci-containers.containers."qbittorrent" = {
    image = "lscr.io/linuxserver/qbittorrent:latest";

    environment = {
      # PUID/PGID=0: linuxserver entrypoint stays as root inside the container.
      # In rootless mode, container root maps to the host "qbt" user (UID 994).
      PUID = "0";
      PGID = "0";
      TZ = config.lanbat.timezone;
      WEBUI_PORT = "8090";
    };

    volumes = [
      "/var/lib/qbittorrent:/config"
      "/srv/storage/a/media:/media/a"
      "/srv/storage/b/media:/media/b"
    ];

    # Do NOT use --network host; bridge mode + port mapping is fine here.
    ports = [ "127.0.0.1:8090:8090" ];

    podman.user = "qbt";
    user = "0";
    autoStart = false; # started by workload-online.target
  };

  systemd.services."podman-qbittorrent" = {
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = "15s";
    };
  };
}

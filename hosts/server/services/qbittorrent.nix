# hosts/server/services/qbittorrent.nix
#
# qBittorrent — torrent client with web UI.
#
# Storage split
# -------------
# Server-local:
#   /var/lib/qbittorrent/   — qBittorrent config, fastresume files, session state
#
# Pi-backed via NFS (/srv/storage/a):
#   /srv/storage/a/downloads/       — default download location
#   /srv/storage/a/downloads/alice/ — per-user download dirs (pre-created)
#   /srv/storage/a/downloads/bob/
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
# One shared instance is enough.  Per-user directories are pre-created so
# users can select their folder in the web UI.
{ config, pkgs, lib, ... }:

{
  # Run qBittorrent as an OCI container to simplify volume mounts and
  # to use the linuxserver.io image which ships a clean web UI.
  virtualisation.oci-containers.containers."qbittorrent" = {
    image = "lscr.io/linuxserver/qbittorrent:latest";

    environment = {
      # PUID/PGID=0: linuxserver entrypoint stays as root inside the container.
      # In rootless mode, container root maps to the host "qbt" user (UID 994).
      PUID          = "0";
      PGID          = "0";
      TZ            = config.lanbat.timezone;
      WEBUI_PORT    = "8090";
    };

    volumes = [
      "/var/lib/qbittorrent:/config"
      "/srv/storage/a/downloads:/downloads"
    ];

    # Do NOT use --network host; bridge mode + port mapping is fine here.
    ports = [ "127.0.0.1:8090:8090" ];

    podman.user = "qbt";
    user = "0";
    autoStart = false; # managed by the NFS dependency below
  };

  # ---------------------------------------------------------------------------
  # NFS dependency — wire the container service to the NFS mount.
  # ---------------------------------------------------------------------------
  lanbat.nfsDependentServices."podman-qbittorrent" = [ "a" ];

  # Also mark autoStart — since we set autoStart=false above, we need to
  # actually start it via the dependency.  Override wantedBy here.
  systemd.services."podman-qbittorrent" = {
    wantedBy   = [ "multi-user.target" ];
    after      = [ "srv-storage-a.mount" ];
    bindsTo    = [ "srv-storage-a.mount" ];
    serviceConfig = {
      Restart    = lib.mkForce "on-failure";
      RestartSec = "15s";
    };
  };

  # Pre-create per-user download directories (add users as needed).
  systemd.tmpfiles.rules = [
    "d /srv/storage/a/downloads            0775 qbt  media -"
    "d /srv/storage/a/downloads/admin      0770 qbt  media -"
    # "d /srv/storage/a/downloads/alice    0770 alice media -"
    # "d /srv/storage/a/downloads/bob      0770 bob   media -"
  ];

  # XFS project quota for the downloads tree.
  # Quota setup requires a manual step — see docs/storage-layout.md.
}

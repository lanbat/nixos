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
# Auth: Authentik, through Caddy's forward auth, is the only login. After it,
#   everyone shares the one instance: qBittorrent skips its own login for
#   requests from the server's address, which is where the rootless port
#   mapping delivers Caddy's requests. The port listens only on the server's
#   loopback, so nothing on the LAN reaches qBittorrent without Authentik.
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
      # Match the host qbt account so NFS media dirs (qbt:media, mode 2775) are writable.
      PUID = toString config.lanbat.services.qbittorrent.account.uid;
      PGID = toString config.users.groups.media.gid;
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

  systemd.services."podman-qbittorrent".serviceConfig = {
    # Set before every start, so the Authentik-only login holds even if the
    # setting is changed in the web UI. As root (+): the container owns its
    # config as whichever user ID it runs under (PUID), which qbt, the unit's
    # user, can't always write. The file is rewritten in place, so it keeps
    # that owner.
    ExecStartPre = lib.mkBefore [
      "+${pkgs.writeShellScript "qbittorrent-web-ui-whitelist" ''
        conf=/var/lib/qbittorrent/qBittorrent/qBittorrent.conf
        [ -f "$conf" ] || exit 0
        tmp=$(${pkgs.coreutils}/bin/mktemp)
        trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
        set_pref() {
          K="$1" V="$2" ${pkgs.gawk}/bin/awk '
            BEGIN { key = ENVIRON["K"] "="; line = key ENVIRON["V"] }
            index($0, key) == 1 { if (!done) print line; done = 1; next }
            { print }
            $0 == "[Preferences]" && !done { print line; done = 1 }
            END { if (!done) { print "[Preferences]"; print line } }
          ' "$conf" > "$tmp" && ${pkgs.coreutils}/bin/cat "$tmp" > "$conf"
        }
        set_pref 'WebUI\AuthSubnetWhitelistEnabled' true
        set_pref 'WebUI\AuthSubnetWhitelist' '${config.lanbat.serverIp}/32, ::ffff:${config.lanbat.serverIp}/128'
      ''}"
    ];
    Restart = lib.mkForce "on-failure";
    RestartSec = "15s";
  };
}

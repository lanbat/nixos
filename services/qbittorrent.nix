# services/qbittorrent.nix
#
# qBittorrent — torrent client with web UI.
#
# Web UI: VueTorrent (pkgs.vuetorrent), which works on phones as well as
#   desktop browsers, unlike qBittorrent's own. qBittorrent serves it as its
#   alternative web UI from the package, mounted read-only into the container,
#   so it updates with nixpkgs and the API (Homepage's widget) is unchanged.
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
    # Homepage's qBittorrent widget calls /api/v2/* without an Authentik session.
    caddy.authBypassPaths = [ "/api/v2/*" ];
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
      widget = {
        type = "qbittorrent";
        username = "admin";
        password = {
          _secret = "QBITTORRENT_PASSWORD";
        };
        enableLeechProgress = true;
      };
    };
  };

  # Run qBittorrent as an OCI container to simplify volume mounts.
  virtualisation.oci-containers.containers."qbittorrent" = {
    image = "lscr.io/linuxserver/qbittorrent:5.2.3";

    environment = {
      # Namespace root maps to the rootless Podman account (host qbt:qbt).
      # Using the host IDs here would map them again through qbt's subordinate
      # ID range, leaving the process unable to write qbt-owned NFS paths.
      PUID = "0";
      PGID = "0";
      TZ = config.lanbat.deployment.timezone;
      WEBUI_PORT = "8090";
    };

    volumes = [
      "/var/lib/qbittorrent:/config"
      "/srv/storage/a/media:/media/a"
      "/srv/storage/b/media:/media/b"
      "${pkgs.vuetorrent}/share/vuetorrent:/vuetorrent:ro"
    ];

    # Host networking avoids pasta's IPv4 fragment drops, which break BitTorrent
    # peer connections in rootless Podman. The web UI stays on loopback via
    # WebUI\Address set in ExecStartPre below.
    extraOptions = [ "--network=host" ];

    podman.user = "qbt";
    user = "0";
    autoStart = false; # started by workload-online.target
  };

  systemd.services."podman-qbittorrent".serviceConfig = {
    # Set before every start, so the Authentik-only login and VueTorrent hold
    # even if the settings are changed in the web UI. As root (+), because
    # existing config files may still carry a subordinate ID from the old PUID
    # mapping. The file is rewritten in place, so it keeps that owner.
    ExecStartPre = lib.mkBefore [
      "+${pkgs.coreutils}/bin/chown -R qbt:qbt /var/lib/qbittorrent"
      "+${pkgs.writeShellScript "qbittorrent-web-ui-prefs" ''
        conf=''${1:-/var/lib/qbittorrent/qBittorrent/qBittorrent.conf}
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
        set_pref 'WebUI\Address' 127.0.0.1
        set_pref 'WebUI\AlternativeUIEnabled' true
        set_pref 'WebUI\RootFolder' /vuetorrent
        set_pref 'WebUI\AuthSubnetWhitelistEnabled' true
        # Host networking: Caddy connects via loopback (127.0.0.1). Bridge/pasta
        # used to rewrite the source to the server IP — keep both.
        set_pref 'WebUI\AuthSubnetWhitelist' '127.0.0.1/32, ::1/128, ${config.lanbat.deployment.serverIp}/32, ::ffff:${config.lanbat.deployment.serverIp}/128'
      ''}"
    ];
    Restart = lib.mkForce "on-failure";
    RestartSec = "15s";
  };
}

# Jackett — torrent indexer aggregator for qBittorrent searches.
#
# The management UI is only reachable through Caddy and Authentik, restricted
# to the Authentik admins: Jackett has one shared admin account and no roles,
# so everyone who gets in can change indexers and read their credentials.
# Jackett's own listener stays private on port 9117 (the module passes no
# --ListenPublic, and no firewall port is opened); qBittorrent reaches it over
# loopback.
#
# State: /var/lib/jackett holds the indexers' credentials, cookies and the API
# key, so it lives on the workload layer. The nixpkgs module's tmpfiles rule for
# its data directory only creates empty directories under the stub while the
# layer is locked, the same as Nextcloud's; workloadDirs gives the mounted
# directories their owner.
#
# qBittorrent: its Jackett search plugin reads
# /var/lib/qbittorrent/qBittorrent/nova3/engines/jackett.json (/config/... in
# the container). jackett-qbittorrent-plugin writes it from the API key Jackett
# generated, before every qBittorrent start, so the key is never typed in or
# kept in the Nix store and a regenerated key is picked up on the next start.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  port = config.lanbat.services.jackett.port;
  dataDir = config.services.jackett.dataDir;

  # The plugin unit and the ordering on qBittorrent exist only on a host that
  # runs qBittorrent; Jackett alone has no plugin to configure.
  withQbittorrent = config.virtualisation.oci-containers.containers ? qbittorrent;

  enginesDir = "/var/lib/qbittorrent/qBittorrent/nova3/engines";
in

{
  lanbat.services.jackett = {
    subdomain = "jackett";
    port = 9117;
    auth = "forward-auth";
    access.groups = lib.mkDefault [ "authentik Admins" ];
    tier = "workload";
    state = [ "jackett" ];
    units = [ "jackett" ] ++ lib.optional withQbittorrent "jackett-qbittorrent-plugin";
    workloadDirs =
      lib.genAttrs
        [
          "jackett"
          "jackett/.config"
          "jackett/.config/Jackett"
        ]
        (_: {
          user = "jackett";
          mode = "0700";
        });
    dashboard = {
      group = "Downloads";
      name = "Jackett";
      description = "Torrent indexer aggregator";
    };
  };

  services.jackett = {
    enable = true;
    inherit port;
    openFirewall = false;
    dataDir = "/var/lib/jackett/.config/Jackett";
  };

  systemd.services = lib.mkIf withQbittorrent {
    jackett-qbittorrent-plugin = {
      description = "Point qBittorrent's Jackett search plugin at Jackett";
      requires = [ "jackett.service" ];
      after = [ "jackett.service" ];
      path = [
        pkgs.coreutils
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Root writes into qBittorrent's state and reads Jackett's private
        # data directory; nothing else is writable.
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/qbittorrent" ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
      script = ''
        config=${dataDir}/ServerConfig.json

        # Jackett writes ServerConfig.json, and with it the key, a moment
        # after it starts.
        key=
        for _ in $(seq 1 60); do
          if [ -s "$config" ]; then
            key=$(jq -r '.APIKey // empty' "$config" 2>/dev/null || true)
            [ -n "$key" ] && break
          fi
          sleep 1
        done
        if [ -z "$key" ] || [ "$key" = YOUR_API_KEY_HERE ]; then
          echo "Jackett has not generated an API key in $config" >&2
          exit 1
        fi

        # Each level belongs to qbt: qBittorrent creates them on its first
        # start, and a root-owned one would be unwritable to it.
        dir=/var/lib/qbittorrent
        for part in qBittorrent nova3 engines; do
          dir=$dir/$part
          install -d -m 0755 -o qbt -g qbt "$dir"
        done

        # Written beside the target and renamed over it, so the plugin never
        # reads half a file. The key goes through jq, not the shell.
        tmp=$(mktemp ${enginesDir}/.jackett.json.XXXXXX)
        trap 'rm -f "$tmp"' EXIT
        jq -n --arg key "$key" \
          '{api_key: $key, url: "http://127.0.0.1:${toString port}", tracker_first: false, thread_count: 20}' \
          > "$tmp"
        chown qbt:qbt "$tmp"
        chmod 0600 "$tmp"
        mv -f "$tmp" ${enginesDir}/jackett.json
      '';
    };

    # Never start with the plugin unconfigured: the plugin writes the
    # placeholder key and fails every search with "api key error".
    podman-qbittorrent = {
      requires = [ "jackett-qbittorrent-plugin.service" ];
      after = [ "jackett-qbittorrent-plugin.service" ];
    };
  };
}

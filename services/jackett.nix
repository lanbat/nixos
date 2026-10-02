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
# A Jackett restart leaves qBittorrent running; it learns a new key when it
# next starts.
#
# Indexers: jackett-indexers adds every public indexer Jackett knows, which
# need no account, and drops the ones whose test fails (dead sites, Cloudflare)
# so they do not slow every search. Private and semi-private indexers need
# credentials and are left to the UI. It only adds indexers that are not
# configured yet, so it never touches ones set up by hand.
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
    units = [
      "jackett"
      "jackett-indexers"
    ]
    ++ lib.optional withQbittorrent "jackett-qbittorrent-plugin";
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
    # Newer than the locked nixpkgs': indexer definitions ship in the build,
    # and an old build fails more of them. See pkgs/jackett.
    package = pkgs.callPackage ../pkgs/jackett { };
    openFirewall = false;
    dataDir = "/var/lib/jackett/.config/Jackett";
  };

  # The module's command line plus --ListenPrivate, so Jackett binds loopback
  # whatever AllowExternal says in its ServerConfig.json (on Linux Jackett
  # otherwise defaults to listening on every interface). The firewall already
  # keeps 9117 closed; this keeps the UI and API off the LAN even if it opens.
  systemd.services = {
    # Type=simple, not oneshot: testing ~100 indexers takes minutes, and a
    # oneshot would hold up switch-to-configuration (and so a deploy) until it
    # finished. Requires= reruns it whenever Jackett restarts.
    jackett-indexers = {
      description = "Add Jackett's public indexers and drop the ones that fail";
      requires = [ "jackett.service" ];
      after = [ "jackett.service" ];
      path = [
        pkgs.bash
        pkgs.coreutils
        pkgs.curl
        pkgs.findutils
        pkgs.jq
      ];
      serviceConfig = {
        Type = "simple";
        User = "jackett";
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
      };
      script = ''
        base=http://127.0.0.1:${toString port}
        export api=$base/api/v2.0/indexers
        jar=$(mktemp)
        trap 'rm -f "$jar"' EXIT
        export jar

        # With no admin password Jackett signs the first visitor in; the
        # session cookie is what the admin API checks.
        up=
        for _ in $(seq 1 120); do
          if curl -fsSL -m 10 -c "$jar" -b "$jar" -o /dev/null "$base/UI/Dashboard"; then
            up=1
            break
          fi
          sleep 1
        done
        if [ -z "$up" ]; then
          echo "Jackett did not answer on $base" >&2
          exit 1
        fi

        list=$(mktemp)
        trap 'rm -f "$jar" "$list"' EXIT
        curl -sS -m 120 -b "$jar" -o "$list" "$api?configured=false" || true
        if ! jq -e 'type == "array"' "$list" >/dev/null 2>&1; then
          echo "Jackett's indexer list is not available; is an admin password set?" >&2
          exit 1
        fi

        # Public indexers only: they need no account. The id goes into a URL,
        # so anything but a plain slug is skipped.
        ids=$(jq -r '.[] | select(.type == "public") | .id' "$list" | grep -E '^[A-Za-z0-9_-]+$' || true)

        add_one() {
          id=$1
          if ! curl -fsS -m 60 -b "$jar" -X POST -H 'Content-Type: application/json' \
              -d '[]' -o /dev/null "$api/$id/config" 2>/dev/null; then
            echo "skipped $id: could not add it"
            return 0
          fi
          if curl -fsS -m 150 -b "$jar" -X POST -o /dev/null "$api/$id/test" 2>/dev/null; then
            echo "added $id"
          else
            curl -fsS -m 60 -b "$jar" -X DELETE -o /dev/null "$api/$id" 2>/dev/null || true
            echo "dropped $id: its test failed"
          fi
        }
        export -f add_one

        printf '%s\n' $ids | xargs -r -P 6 -I{} bash -c 'add_one "$1"' _ {}

        echo "configured indexers: $(curl -sS -m 60 -b "$jar" "$api?configured=true" | jq length)"
      '';
    };

    jackett.serviceConfig.ExecStart = lib.mkForce (
      "${config.services.jackett.package}/bin/Jackett --NoUpdates --ListenPrivate"
      + " --Port ${toString port} --DataFolder '${dataDir}'"
    );

    jackett-qbittorrent-plugin = lib.mkIf withQbittorrent {
      description = "Point qBittorrent's Jackett search plugin at Jackett";
      requires = [ "jackett.service" ];
      after = [ "jackett.service" ];
      path = [
        pkgs.coreutils
        pkgs.jq
      ];
      serviceConfig = {
        # Not RemainAfterExit: the unit is inactive between runs, so starting
        # qBittorrent (which Requires it) runs it again, every time. It is
        # also not restarted when Jackett restarts, so neither is qBittorrent.
        Type = "oneshot";
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
    podman-qbittorrent = lib.mkIf withQbittorrent {
      requires = [ "jackett-qbittorrent-plugin.service" ];
      after = [ "jackett-qbittorrent-plugin.service" ];
    };
  };
}

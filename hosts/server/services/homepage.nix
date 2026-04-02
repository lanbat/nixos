# hosts/server/services/homepage.nix
#
# Homepage — dynamic service dashboard.
#
# Serves as the main LAN landing page at home.<domain>.
# Shows all services with health widgets where supported.
# No authentication — it's the entry point.
{ config, pkgs, lib, ... }:

let domain = config.lanbat.domain; in

{
  virtualisation.oci-containers.containers."homepage" = {
    image = "ghcr.io/gethomepage/homepage:latest";

    volumes = [
      "/var/lib/homepage/config:/app/config"
      "/var/run/podman/podman.sock:/var/run/docker.sock:ro"
    ];

    ports = [ "127.0.0.1:3000:3000" ];

    environment = {
      HOMEPAGE_ALLOWED_HOSTS = "home.${domain},localhost";
    };

    autoStart = true;
  };

  # Write Homepage config files.
  systemd.services."homepage-init-config" = {
    description = "Initialize Homepage config";
    before      = [ "podman-homepage.service" ];
    wantedBy    = [ "podman-homepage.service" ];
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = pkgs.writeShellScript "homepage-init" ''
        mkdir -p /var/lib/homepage/config
        if [ ! -f /var/lib/homepage/config/services.yaml ]; then
          cat > /var/lib/homepage/config/services.yaml << 'YAML'
- Identity & Auth:
    - Authentik:
        href: https://auth.${domain}
        description: Identity & SSO
        icon: authentik
        widget:
          type: authentik
          url: http://localhost:9000
          key: CHANGE_ME_HOMEPAGE_AUTHENTIK_API_KEY

- Media:
    - Jellyfin:
        href: https://media.${domain}
        description: Media Server
        icon: jellyfin
        widget:
          type: jellyfin
          url: http://localhost:8096
          key: CHANGE_ME_JELLYFIN_API_KEY
    - Immich:
        href: https://photos.${domain}
        description: Photo Library
        icon: immich
        widget:
          type: immich
          url: http://localhost:2283
          key: CHANGE_ME_IMMICH_API_KEY

- Files & Sync:
    - Nextcloud:
        href: https://cloud.${domain}
        description: File Sync
        icon: nextcloud
        widget:
          type: nextcloud
          url: https://cloud.${domain}
          username: admin
          password: CHANGE_ME

- Downloads:
    - qBittorrent:
        href: https://torrent.${domain}
        description: Torrent Client
        icon: qbittorrent
        widget:
          type: qbittorrent
          url: http://localhost:8090
          username: admin
          password: CHANGE_ME
    - Bitmagnet:
        href: https://bitmagnet.${domain}
        description: DHT Search (on-demand)
        icon: bitmagnet

- Automation:
    - Home Assistant:
        href: https://ha.${domain}
        description: Home Automation
        icon: home-assistant
        widget:
          type: homeassistant
          url: http://localhost:8123
          key: CHANGE_ME_HA_LONG_LIVED_TOKEN

- Surveillance:
    - Frigate:
        href: https://nvr.${domain}
        description: NVR
        icon: frigate
        widget:
          type: frigate
          url: http://localhost:5000

- Utilities:
    - Search:
        href: https://search.${domain}
        description: Metasearch (no auth)
        icon: searxng
YAML
        fi

        if [ ! -f /var/lib/homepage/config/settings.yaml ]; then
          cat > /var/lib/homepage/config/settings.yaml << 'YAML'
title: Homelab
favicon: https://home.${domain}/favicon.ico
theme: dark
color: slate
headerStyle: boxed
YAML
        fi

        if [ ! -f /var/lib/homepage/config/widgets.yaml ]; then
          cat > /var/lib/homepage/config/widgets.yaml << 'YAML'
- resources:
    cpu: true
    memory: true
    disk: /
- datetime:
    text_size: l
    format:
      dateStyle: long
      timeStyle: short
YAML
        fi

        if [ ! -f /var/lib/homepage/config/docker.yaml ]; then
          cat > /var/lib/homepage/config/docker.yaml << 'YAML'
my-server:
  socket: /var/run/podman/podman.sock
YAML
        fi
      '';
      RemainAfterExit = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homepage        0750 root root -"
    "d /var/lib/homepage/config 0750 root root -"
  ];
}

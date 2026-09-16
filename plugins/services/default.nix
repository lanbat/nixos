# plugins/services/default.nix
#
# Built-in server services plugin — all homelab services in services/.
{
  name = "lanbat-services";
  version = 1;
  roles = [ "server" ];
  modules = [
    ../../services/authentik
    ../../services/bitmagnet.nix
    ../../services/caddy.nix
    ../../services/frigate.nix
    ../../services/grafana.nix
    ../../services/home-assistant.nix
    ../../services/homepage.nix
    ../../services/immich.nix
    ../../services/influxdb.nix
    ../../services/jellyfin.nix
    ../../services/mosquitto.nix
    ../../services/music-assistant.nix
    ../../services/nextcloud.nix
    ../../services/postgresql.nix
    ../../services/romm.nix
    ../../services/qbittorrent.nix
    ../../services/redis.nix
    ../../services/samba.nix
    ../../services/searxng.nix
    ../../services/snapcast.nix
    ../../services/syncthing.nix
    ../../services/tang.nix
    ../../services/telegraf.nix
    ../../services/vaultwarden.nix
    ../../services/wyoming.nix
    ../../services/zigbee2mqtt.nix
  ];
}

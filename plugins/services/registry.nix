# plugins/services/registry.nix
#
# The built-in server services, by name.
#
# lib/ reads this before NixOS evaluation begins, so that a host imports only
# the services its deploy entry names in hosts.<key>.services. That is why it
# is plain data rather than a NixOS module: nothing can be read out of a
# configuration that has not been built yet.
#
# A key names a module, which is not always a single lanbat.services.<name>:
# the postgresql module describes both postgresql and postgresql-always-on.
# voice-satellite is described by modules/core/voice-satellite.nix, which every
# host imports, so it is not selectable here.
{
  authentik = ../../services/authentik;
  bitmagnet = ../../services/bitmagnet.nix;
  caddy = ../../services/caddy.nix;
  frigate = ../../services/frigate.nix;
  grafana = ../../services/grafana.nix;
  home-assistant = ../../services/home-assistant.nix;
  homepage = ../../services/homepage.nix;
  immich = ../../services/immich.nix;
  influxdb = ../../services/influxdb.nix;
  jellyfin = ../../services/jellyfin.nix;
  mosquitto = ../../services/mosquitto.nix;
  music-assistant = ../../services/music-assistant.nix;
  nextcloud = ../../services/nextcloud.nix;
  postgresql = ../../services/postgresql.nix;
  qbittorrent = ../../services/qbittorrent.nix;
  redis = ../../services/redis.nix;
  romm = ../../services/romm.nix;
  samba = ../../services/samba.nix;
  searxng = ../../services/searxng.nix;
  snapcast = ../../services/snapcast.nix;
  syncthing = ../../services/syncthing.nix;
  tang = ../../services/tang.nix;
  telegraf = ../../services/telegraf.nix;
  vaultwarden = ../../services/vaultwarden.nix;
  wyoming = ../../services/wyoming.nix;
  zigbee2mqtt = ../../services/zigbee2mqtt.nix;
}

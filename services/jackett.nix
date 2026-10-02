# Jackett — torrent indexer aggregator for qBittorrent searches.
#
# The management UI is only reachable through Caddy and Authentik. Jackett's
# own listener remains private on port 9117; qBittorrent uses it over loopback.
# Its indexer credentials, cookies, and API key are workload state.
{ config, lib, ... }:

{
  lanbat.services.jackett = {
    subdomain = "jackett";
    port = 9117;
    auth = "forward-auth";
    access.groups = lib.mkDefault [ "authentik Admins" ];
    tier = "workload";
    state = [ "jackett" ];
    units = [ "jackett" ];
    dashboard = {
      group = "Downloads";
      name = "Jackett";
      description = "Torrent indexer aggregator";
    };
  };

  services.jackett = {
    enable = true;
    port = config.lanbat.services.jackett.port;
    openFirewall = false;
    dataDir = "/var/lib/jackett/.config/Jackett";
  };
}

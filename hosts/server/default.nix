# hosts/server/default.nix
#
# Main server configuration. Importing a file from services/ enables that
# service; everything else about it (vhost, tier, account, secrets, dashboard)
# is declared in the file itself.
{
  config,
  pkgs,
  ...
}:

{
  imports = [
    ./hardware.nix
    ./disk.nix

    ../../modules/core
    ../../modules/server/control-layer.nix
    ../../modules/server/backups.nix
    ../../modules/wiring/caddy.nix
    ../../modules/wiring/nfs.nix
    ../../modules/wiring/on-demand.nix
    ../../modules/wiring/workload-gate.nix

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
    ../../services/nextcloud.nix
    ../../services/postgresql.nix
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

  networking.hostName = config.lanbat.serverHostname;

  # ---------------------------------------------------------------------------
  # Boot
  # ---------------------------------------------------------------------------
  # No passphrase at boot: the host root is unencrypted and both LUKS layers
  # stay locked until an admin runs unlock-control and unlock-workload.
  # See modules/server/control-layer.nix.
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------
  networking = {
    useNetworkd = true;
    interfaces.${config.lanbat.serverInterface} = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = config.lanbat.serverIp;
          prefixLength = 24;
        }
      ];
    };
    defaultGateway = {
      address = config.lanbat.gatewayIp;
      interface = config.lanbat.serverInterface;
    };
    nameservers = [
      config.lanbat.gatewayIp
      "1.1.1.1"
    ];
  };

  # Services open their own ports in their files.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [
      5353 # mDNS (Home Assistant discovery)
    ];
  };

  # ---------------------------------------------------------------------------
  # Container runtime (Podman)
  # ---------------------------------------------------------------------------
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
    autoPrune.enable = true;
    autoPrune.dates = "weekly";
  };

  virtualisation.oci-containers.backend = "podman";

  systemd.tmpfiles.rules = [
    "d /var/lib/homelab 0755 root root -"
  ];

  users.users.admin.extraGroups = [
    "media"
    "private"
  ];

  # Helper scripts (the domain is substituted at build time).
  environment.systemPackages = [
    (pkgs.callPackage ../../pkgs/scripts { inherit (config.lanbat) domain; })
  ];

  system.stateVersion = "24.11";
}

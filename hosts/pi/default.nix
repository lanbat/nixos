# hosts/pi/default.nix
#
# Raspberry Pi 5 configuration.
#
# Roles:
#   1. Encrypted storage appliance: two LUKS drives unlocked automatically
#      via Clevis/Tang on the server.
#   2. NFS export of both drives to the server.
#   3. TV frontend: Kodi and RetroArch via a simple launcher.
#
# Heavy compute, databases and containers all live on the server.
{ config, pkgs, ... }:

{
  imports = [
    ./hardware.nix

    ../../modules/core

    ../../modules/pi/clevis-unlock.nix
    ../../modules/pi/frontend.nix
    ../../modules/pi/launcher.nix
    ../../modules/pi/nfs-exports.nix
    ../../modules/pi/snapclient.nix
    ../../modules/pi/storage.nix
    ../../modules/pi/telegraf.nix
    ../../modules/pi/wyoming-satellite.nix
  ];

  networking.hostName = config.lanbat.piHostname;

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------
  networking = {
    useNetworkd = true;
    # Static IP: the server's NFS mounts and firewall rules need a stable address.
    interfaces.${config.lanbat.piInterface} = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = config.lanbat.piIp;
          prefixLength = 24;
        }
      ];
    };
    defaultGateway = {
      address = config.lanbat.gatewayIp;
      interface = config.lanbat.piInterface;
    };
    nameservers = [ config.lanbat.gatewayIp ];
  };

  # SSH, NFS for the server, and the Wyoming satellite for the server's HA.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22
      2049
      111
      10700
    ];
    allowedUDPPorts = [ 5353 ]; # mDNS — Wyoming satellite auto-discovery by HA
    # NFS and the Wyoming satellite only accept the server.
    extraCommands = ''
      iptables -I INPUT -p tcp --dport 2049  ! -s ${config.lanbat.serverIp} -j DROP
      iptables -I INPUT -p udp --dport 2049  ! -s ${config.lanbat.serverIp} -j DROP
      iptables -I INPUT -p tcp --dport 10700 ! -s ${config.lanbat.serverIp} -j DROP
    '';
  };

  services.timesyncd.enable = true;

  # Minimal package set; the Pi should stay lean.
  environment.systemPackages = with pkgs; [
    clevis
    tang
    nfs-utils
    xfsprogs
    cryptsetup
    smartmontools
  ];

  # The Pi boots through its firmware, not GRUB.
  boot.loader.grub.enable = false;

  system.stateVersion = "24.11";
}

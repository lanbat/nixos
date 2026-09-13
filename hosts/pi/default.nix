# hosts/pi/default.nix
#
# Raspberry Pi 5 configuration.
#
# Roles:
#   1. Encrypted storage appliance: two LUKS drives unlocked automatically
#      via Clevis/Tang on the server.
#   2. NFS export of both drives to the server.
#   3. TV frontend: Kodi and EmulationStation sessions, when
#      lanbat.piTvFrontend is set (modules/pi/tv.nix).
#
# Heavy compute, databases and containers all live on the server.
#
# The Raspberry Pi 5 hardware support (./hardware.nix) is added next to this
# module in flake.nix, so the VM test (tests/pi.nix) can boot the rest of the
# configuration without it.
{ config, pkgs, ... }:

{
  imports = [
    ../../modules/core

    ../../modules/pi/audio.nix
    ../../modules/pi/clevis-unlock.nix
    ../../modules/pi/nfs-exports.nix
    ../../modules/pi/snapclient.nix
    ../../modules/pi/storage.nix
    ../../modules/pi/telegraf.nix
    ../../modules/pi/tv.nix
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

  # Voice satellite for the server's Home Assistant (modules/core/voice-satellite.nix):
  # the PlayStation Eye's microphones, replies on the TV through PipeWire
  # (modules/pi/audio.nix).
  lanbat.voiceSatellite = {
    enable = true;
    name = "Pi Satellite";
    uri = "tcp://0.0.0.0:10700";
    room = config.lanbat.voiceRooms.pi;
    # Through Caddy, which lets /api/* past Authentik for Home Assistant.
    homeAssistant = {
      url = "https://ha.${config.lanbat.domain}";
      caFile = ../../secrets/caddy-ca-root.crt;
    };
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

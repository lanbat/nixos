# lib/roles/voice-pi.nix
#
# Voice Pi role: lightweight host for a Wyoming voice satellite endpoint.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  host = config.lanbat.hosts.${config.lanbat.hostKey};
  net = host.networking;
  networkLib = import ../network.nix { inherit lib; };
  prefixLength = networkLib.prefixLengthFromCidr config.lanbat.deployment.lanSubnet;
in
{
  networking.hostName = net.hostname;

  # The Pi reboots cleanly (Clevis/Tang unlocks LUKS), so it may auto-reboot
  # within the nightly window.
  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    rebootWindow = {
      lower = "04:00";
      upper = "06:00";
    };
  };

  networking = {
    useNetworkd = true;
    interfaces.${net.interface} = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = net.ip;
          inherit prefixLength;
        }
      ];
    };
    defaultGateway = {
      address = config.lanbat.deployment.gatewayIp;
      interface = net.interface;
    };
    nameservers = [ config.lanbat.deployment.gatewayIp ];
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [ 5353 ];
    # The satellite's port is opened and restricted by
    # modules/wiring/policy.nix, from the edge Home Assistant declares.
  };

  services.timesyncd.enable = true;

  environment.systemPackages = with pkgs; [ ];

  boot.loader.grub.enable = false;

  system.stateVersion = "24.11";
}

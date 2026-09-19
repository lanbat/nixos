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
  serverIp =
    let
      serverKey = config.lanbat.deployment.primaryServer;
    in
    if serverKey == null then "127.0.0.1" else config.lanbat.hosts.${serverKey}.networking.ip;
in
{
  networking.hostName = net.hostname;

  # Auto-upgrade is disabled: the Pi has no flake checkout (deployments are
  # driven from the workstation via deploy-rs), so the built-in timer had nothing
  # to build and failed every run. Upgrades are applied manually with `deploy`.
  system.autoUpgrade.enable = false;

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
    allowedTCPPorts = [
      22
      10700
    ];
    allowedUDPPorts = [ 5353 ];
    extraCommands = ''
      iptables -I INPUT -p tcp --dport 10700 ! -s ${serverIp} -j DROP
    '';
  };

  services.timesyncd.enable = true;

  environment.systemPackages = with pkgs; [ ];

  boot.loader.grub.enable = false;

  system.stateVersion = "24.11";
}

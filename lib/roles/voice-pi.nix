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
  flakeAttr =
    if config.lanbat.profile == "default" then
      config.lanbat.hostKey
    else
      "${config.lanbat.profile}-${config.lanbat.hostKey}";
  serverIp =
    let
      serverKey = config.lanbat.deployment.primaryServer;
    in
    if serverKey == null then "127.0.0.1" else config.lanbat.hosts.${serverKey}.networking.ip;
in
{
  networking.hostName = net.hostname;

  system.autoUpgrade = {
    enable = true;
    flake = "path:/etc/nixos#${flakeAttr}";
    allowReboot = true;
    rebootWindow = {
      lower = "04:00";
      upper = "06:00";
    };
    dates = "04:30";
    randomizedDelaySec = "30min";
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

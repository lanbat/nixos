# lib/roles/server.nix
#
# Server role: main compute host, reverse proxy, databases, containers.
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
in
{
  networking.hostName = net.hostname;

  system.autoUpgrade = {
    enable = true;
    flake = "path:/etc/nixos#${flakeAttr}";
    allowReboot = false;
    dates = "04:00";
    randomizedDelaySec = "30min";
  };

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
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
    nameservers = [
      config.lanbat.deployment.gatewayIp
      "1.1.1.1"
    ];
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [ 5353 ];
  };

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

  environment.systemPackages = [
    (pkgs.callPackage ../../pkgs/scripts { inherit (config.lanbat.deployment) domain; })
  ];

  system.stateVersion = "24.11";
}

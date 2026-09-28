# lib/roles/server.nix
#
# Server role: main compute host, reverse proxy, databases, containers.
# Hostname, static address and firewall baseline come from
# lib/roles/common.nix.
args@{
  config,
  pkgs,
  lib,
  ...
}:

{
  config = lib.mkMerge [
    (import ./common.nix args)
    {
      boot.loader = {
        systemd-boot.enable = true;
        efi.canTouchEfiVariables = true;
      };

      # A public resolver after the gateway, for when the gateway's DNS is down.
      networking.nameservers = [ "1.1.1.1" ];

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
    }
  ];
}

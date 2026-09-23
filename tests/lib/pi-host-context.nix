# tests/lib/pi-host-context.nix
#
# Injects deploy.example.nix pi-storage host context for VM tests.
{ lib, ... }:

let
  deploy = import ../../deployments/example/deploy.nix {
    inputs = {
      self = {
        lanbatPlugins = {
          services = import ../../plugins/services;
          tv = import ../../plugins/tv;
          voice = import ../../plugins/voice;
        };
      };
    };
  };

  profileName = "example";
  hostKey = "pi-storage";
in
{
  lanbat.profile = lib.mkDefault profileName;
  lanbat.hostKey = lib.mkDefault hostKey;
  lanbat.deployment = lib.mkDefault deploy.deployment;
  lanbat.hosts = lib.mkDefault (
    lib.mapAttrs (
      name: host:
      let
        base = {
          role = host.role;
          networking = host.networking;
          disks = host.disks or { };
          storage = host.storage or { };
          overlay = host.overlay or null;
        };
      in
      if name == hostKey then
        lib.recursiveUpdate base {
          networking = base.networking // {
            interface = "eth1";
            ip = "192.168.1.2";
          };
        }
      else
        base
    ) deploy.hosts
  );
}

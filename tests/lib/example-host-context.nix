# tests/lib/example-host-context.nix
#
# Injects deploy.example.nix host context for VM tests.
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
  hostKey = "server";
in
{
  lanbat.profile = lib.mkDefault profileName;
  lanbat.hostKey = lib.mkDefault hostKey;
  lanbat.deployment = lib.mkDefault deploy.deployment;
  lanbat.hosts = lib.mkDefault (
    lib.mapAttrs (name: host: {
      role = host.role;
      networking = host.networking;
      disks = host.disks or { };
      storage = host.storage or { };
    }) deploy.hosts
  );
}

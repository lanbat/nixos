# lib/mkHost.nix
#
# Builds one nixosSystem from a deploy host entry.
{
  lib,
  inputs,
  agenix,
  disko,
  nixos-raspberrypi,
  profileName,
  deployment,
  hosts,
  hostName,
  hostCfg,
}:

let
  inherit (import ./plugins.nix { inherit lib; }) resolvePlugins;
  inherit (import ./roles.nix { inherit lib; }) getRoleModules;

  platform = hostCfg.platform or "generic";
  system = hostCfg.system;

  pluginModules = resolvePlugins hostCfg.role (hostCfg.plugins or [ ]);

  hostContextModule =
    { ... }:
    {
      lanbat.profile = profileName;
      lanbat.hostKey = hostName;
      lanbat.deployment = deployment;
      lanbat.hosts = lib.mapAttrs (name: host: {
        role = host.role;
        networking = host.networking;
        disks = host.disks or { };
        storage = host.storage or { };
      }) hosts;
    };

  commonModules = [
    agenix.nixosModules.default
    { nixpkgs.config.allowUnfree = true; }
    ../modules/core
    hostContextModule
  ]
  ++ getRoleModules hostCfg.role
  ++ pluginModules;

  raspberryPiModules = commonModules ++ [
    ../hosts/pi/hardware.nix
  ];

  genericModules =
    commonModules
    ++ lib.optionals (hostCfg.role == "server") [
      disko.nixosModules.disko
    ];

  modules = if platform == "raspberry-pi" then raspberryPiModules else genericModules;

  nixosSystem =
    if platform == "raspberry-pi" then
      nixos-raspberrypi.lib.nixosSystem {
        specialArgs = {
          inherit inputs nixos-raspberrypi;
          lanbatHostName = hostName;
        };
        inherit modules;
      }
    else
      lib.nixosSystem {
        inherit system modules;
        specialArgs = {
          inherit inputs;
          lanbatHostName = hostName;
        };
      };
in
nixosSystem
// {
  lanbatModules = modules;
}

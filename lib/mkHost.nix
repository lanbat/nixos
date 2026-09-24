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
  # Profile-wide service table from lib/default.nix. Empty during the first,
  # descriptions-only pass that produces it.
  endpoints ? { },
  # Modules from the deployment's gitignored local/ directory
  # (lib/local-modules.nix).
  localModules ? [ ],
}:

let
  inherit (import ./plugins.nix { inherit lib; }) resolvePlugins settingsModules legacyPlugins;
  inherit (import ./roles.nix { inherit lib; }) getRoleModules;

  platform = hostCfg.platform or "generic";
  system = hostCfg.system;

  pluginModules = resolvePlugins hostCfg.role (hostCfg.plugins or [ ]) (hostCfg.services or [ ]);

  # Deployment settings are profile-wide, so every host declares the namespaces
  # of every plugin enabled anywhere in the profile.
  pluginSettingsModules = settingsModules (
    lib.concatMap (h: h.plugins or [ ]) (lib.attrValues hosts)
  );

  legacy = legacyPlugins (hostCfg.plugins or [ ]);

  # Merged last of all, so a deployment overrides anything core, the role or
  # a plugin set without having to edit a tracked file. The deploy entry's own
  # modules come first, then the ones found in the deployment's local/.
  userModules = (hostCfg.modules or [ ]) ++ localModules;

  hostContextModule =
    { ... }:
    {
      lanbat.profile = profileName;
      lanbat.hostKey = hostName;
      lanbat.deployment = deployment;
      lanbat.endpoints = endpoints;
      lanbat.hosts = lib.mapAttrs (name: host: {
        role = host.role;
        networking = host.networking;
        disks = host.disks or { };
        storage = host.storage or { };
        overlay = host.overlay or null;
        # Needed by the endpoint wiring to work out which host runs a service.
        services = host.services or [ ];
      }) hosts;

      warnings = map (
        name:
        "lanbat plugin '${name}' uses contract version 1. It still loads; see"
        + " docs/plugins.md for moving it to version 2."
      ) legacy;
    };

  # Chosen from deploy data, which exists before any evaluation, so the module
  # can simply be imported rather than selected inside the configuration.
  overlayProviders = import ./overlay-providers.nix;
  overlayName = deployment.overlay.provider or "none";
  overlayModule =
    overlayProviders.${overlayName} or (builtins.throw (
      "lanbat: no overlay provider named \"${overlayName}\". Available: "
      + lib.concatStringsSep ", " (lib.attrNames overlayProviders)
      + "."
    ));

  commonModules = [
    agenix.nixosModules.default
    { nixpkgs.config.allowUnfree = true; }
    ../modules/core
    hostContextModule
  ]
  ++ [ overlayModule ]
  ++ getRoleModules hostCfg.role
  ++ pluginSettingsModules
  ++ pluginModules;

  raspberryPiModules = commonModules ++ [
    ../hosts/pi/hardware.nix
  ];

  genericModules =
    commonModules
    ++ lib.optionals (hostCfg.role == "server") [
      disko.nixosModules.disko
    ];

  modules =
    (if platform == "raspberry-pi" then raspberryPiModules else genericModules) ++ userModules;

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

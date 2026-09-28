# lib/roles.nix
#
# The modules each host role bundles, in the order lib/mkHost.nix imports them.
#
# Every bundled module has a name, so a host can replace or drop it from its
# deploy entry without editing this file:
#
#   hosts.server.roleModules = {
#     wiring-caddy = null;               # drop the Caddy wiring
#     backups = ./my-backups.nix;        # replace the backup module
#   };
#
# A replacement takes the place of the module it replaces, so the rest keep
# their order. Naming a module the role does not bundle fails evaluation.
{ lib }:

let
  root = ../.;

  bundle = name: module: { inherit name module; };

  roleModules = {
    server = [
      (bundle "role" (root + "/lib/roles/server.nix"))
      (bundle "hardware" (root + "/hosts/server/hardware.nix"))
      (bundle "disk" (root + "/hosts/server/disk.nix"))
      (bundle "control-layer" (root + "/modules/server/control-layer.nix"))
      (bundle "backups" (root + "/modules/server/backups.nix"))
      (bundle "wiring-caddy" (root + "/modules/wiring/caddy.nix"))
      (bundle "wiring-nfs" (root + "/modules/wiring/nfs.nix"))
      (bundle "wiring-on-demand" (root + "/modules/wiring/on-demand.nix"))
      (bundle "wiring-workload-gate" (root + "/modules/wiring/workload-gate.nix"))
    ];

    storage-pi = [
      (bundle "role" (root + "/lib/roles/storage-pi.nix"))
      (bundle "clevis-unlock" (root + "/modules/pi/clevis-unlock.nix"))
      (bundle "nfs-exports" (root + "/modules/pi/nfs-exports.nix"))
      (bundle "storage" (root + "/modules/pi/storage.nix"))
      (bundle "user-quotas" (root + "/modules/pi/user-quotas.nix"))
      (bundle "snapclient" (root + "/modules/pi/snapclient.nix"))
      (bundle "telegraf" (root + "/modules/pi/telegraf.nix"))
    ];

    voice-pi = [
      (bundle "role" (root + "/lib/roles/voice-pi.nix"))
      (bundle "audio" (root + "/modules/pi/audio.nix"))
      (bundle "telegraf" (root + "/modules/pi/telegraf.nix"))
    ];
  };

  bundledOf =
    role:
    if !(roleModules ? ${role}) then
      builtins.throw "unknown lanbat host role '${role}'; known roles: ${lib.concatStringsSep ", " (lib.attrNames roleModules)}"
    else
      roleModules.${role};

  # The role's modules with a host's overrides applied: each name in
  # `overrides` maps to a replacement module, a list of them, or null for none.
  resolveRoleModules =
    role: overrides:
    let
      bundled = bundledOf role;
      names = map (b: b.name) bundled;
      unknown = lib.filter (name: !(lib.elem name names)) (lib.attrNames overrides);
      replace =
        b:
        if !(overrides ? ${b.name}) then
          [ b.module ]
        else if overrides.${b.name} == null then
          [ ]
        else
          lib.toList overrides.${b.name};
    in
    if unknown != [ ] then
      builtins.throw (
        "roleModules: role '${role}' bundles no module named "
        + lib.concatStringsSep ", " unknown
        + "; it bundles "
        + lib.concatStringsSep ", " names
      )
    else
      lib.concatMap replace bundled;

  getRoleModules = role: resolveRoleModules role { };

in
{
  inherit roleModules getRoleModules resolveRoleModules;
}

# lib/roles.nix
#
# Maps role names to their NixOS module paths.
{ lib }:

let
  root = ../.;

  roleModules = {
    server = [
      (root + "/lib/roles/server.nix")
      (root + "/hosts/server/hardware.nix")
      (root + "/hosts/server/disk.nix")
      (root + "/modules/server/control-layer.nix")
      (root + "/modules/server/backups.nix")
      (root + "/modules/wiring/caddy.nix")
      (root + "/modules/wiring/nfs.nix")
      (root + "/modules/wiring/on-demand.nix")
      (root + "/modules/wiring/workload-gate.nix")
    ];

    storage-pi = [
      (root + "/lib/roles/storage-pi.nix")
      (root + "/modules/pi/clevis-unlock.nix")
      (root + "/modules/pi/nfs-exports.nix")
      (root + "/modules/pi/storage.nix")
      (root + "/modules/pi/user-quotas.nix")
      (root + "/modules/pi/snapclient.nix")
      (root + "/modules/pi/telegraf.nix")
    ];

    voice-pi = [
      (root + "/lib/roles/voice-pi.nix")
      (root + "/modules/pi/audio.nix")
      (root + "/modules/pi/telegraf.nix")
    ];
  };

  getRoleModules =
    role:
    if !(roleModules ? ${role}) then
      builtins.throw "unknown lanbat host role '${role}'; known roles: ${lib.concatStringsSep ", " (lib.attrNames roleModules)}"
    else
      roleModules.${role};

in
{
  inherit roleModules getRoleModules;
}

# tests/private-media.nix
#
# media/adult is for the private group alone (docs/deployment-checklist.md: the
# hidden Samba "private" share). Pure evaluation of the example profile, whose
# storage Pi runs the TV session:
#
#   - the TV's auto-login account is not in the private group, and Kodi seeds
#     no source for the folder, so nobody at the TV can browse it;
#   - the drive's init keeps everything inside the folder in the private group
#     with no access for others, so a file moved in from elsewhere does not stay
#     readable to every media user behind the folder's own lock.
{
  lib,
  pkgs,
  inputs,
  self,
  agenix,
  disko,
  deploy-rs,
  nixpkgs,
  nixos-raspberrypi,
}:

let
  inputsWithSelf = inputs // {
    self = self // {
      lanbatPlugins = import ../plugins;
    };
  };

  exampleDeploy = import ../deployments/example/deploy.nix { inputs = inputsWithSelf; };

  lanbatLib = import ../lib {
    self = inputsWithSelf.self;
    inputs = inputsWithSelf;
    profiles = { };
    inherit
      nixpkgs
      nixos-raspberrypi
      agenix
      disko
      deploy-rs
      ;
  };

  pi = (lanbatLib.mkProfile "example" exampleDeploy).configurations.example-pi-storage.config;

  initB = pi.systemd.services."storage-b-init".serviceConfig.ExecStart.text;

  checks = {
    "the example Pi runs the TV session" = pi.users.users ? media;
    "the TV account is not in the private group" =
      !(lib.elem "private" pi.users.users.media.extraGroups);
    "Kodi's seeded sources leave out the private folder" =
      !(lib.hasInfix "media/adult" (builtins.readFile ../pkgs/kodi-tv-config/sources.xml));
    "Kodi's library bootstrap leaves out the private folder" =
      !(lib.hasInfix "media/adult" (builtins.readFile ../pkgs/kodi-bootstrap/bootstrap-kodi.sh));
    "the drive init keeps the folder's contents private" =
      lib.hasInfix ''chgrp -R ${toString pi.users.groups.private.gid} "$base/media/adult"'' initB
      && lib.hasInfix ''chmod -R o-rwx "$base/media/adult"'' initB;
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
if failed != [ ] then
  throw "private-media: failed: ${lib.concatStringsSep "; " failed}"
else
  pkgs.runCommand "private-media" { } ''
    echo ${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.attrNames checks))} > $out
  ''

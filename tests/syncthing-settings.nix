# tests/syncthing-settings.nix
#
# lanbat.services.syncthing.settings renders the devices and folders it
# describes into services.syncthing.settings, and rejects devices and folders
# Syncthing could not use. Pure evaluation: the derivation only builds when
# every case holds.
{ lib, pkgs }:

let
  evalSyncthing =
    settings:
    (lib.nixosSystem {
      modules = [
        ../modules/core/services.nix
        ../modules/wiring/accounts.nix
        ../services/syncthing.nix
        {
          boot.isContainer = true;
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "25.11";
          lanbat.services.syncthing.settings = settings;
        }
      ];
    }).config;

  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);

  rejects =
    config: !(builtins.tryEval (builtins.deepSeq config.services.syncthing.settings true)).success;

  laptopId = "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH";
  phoneId = "IIIIIII-JJJJJJJ-KKKKKKK-LLLLLLL-MMMMMMM-NNNNNNN-OOOOOOO-PPPPPPP";

  twoFolders = {
    devices = {
      laptop.id = laptopId;
      phone.id = phoneId;
    };
    folders = {
      "abcde-12345" = {
        label = "Phone files";
        path = "/srv/storage/b/users/admin/sync/phone-files";
        devices = [
          "laptop"
          "phone"
        ];
      };
      "music-xyz" = {
        label = "Music";
        path = "/srv/storage/b/media/music";
        ignorePerms = true;
        devices = [ "laptop" ];
      };
    };
  };

  valid = evalSyncthing twoFolders;
  rendered = valid.services.syncthing.settings;

  checks = {
    "valid settings pass assertions" = failedAssertions valid == [ ];
    "devices render by name" =
      rendered.devices.laptop.id == laptopId && rendered.devices.phone.id == phoneId;
    "folders keep their ids and paths" =
      rendered.folders."abcde-12345".path == "/srv/storage/b/users/admin/sync/phone-files"
      && rendered.folders."music-xyz".path == "/srv/storage/b/media/music";
    "folder devices are device names" =
      rendered.folders."abcde-12345".devices == [
        "laptop"
        "phone"
      ];
    "type defaults to sendreceive" = rendered.folders."abcde-12345".type == "sendreceive";
    "ignorePerms passes through" =
      rendered.folders."music-xyz".ignorePerms && !rendered.folders."abcde-12345".ignorePerms;
    "every folder disables the fs watcher" = lib.all (f: f.fsWatcherEnabled == false) (
      lib.attrValues rendered.folders
    );
    "empty settings render nothing" =
      let
        empty = evalSyncthing { };
      in
      failedAssertions empty == [ ]
      && empty.services.syncthing.settings.folders == { }
      && empty.services.syncthing.settings.devices == { };
    "groups default to none" = !(lib.elem "media" valid.users.users.syncthing.extraGroups);
    "groups pass to the syncthing user" =
      lib.elem "media"
        (evalSyncthing {
          groups = [ "media" ];
        }).users.users.syncthing.extraGroups;
    # A deploy only restarts a unit whose definition changed; group membership
    # alone would leave the running Syncthing without the new group.
    "groups are on the syncthing unit, so a change restarts it" =
      lib.elem "media"
        (evalSyncthing {
          groups = [ "media" ];
        }).systemd.services.syncthing.serviceConfig.SupplementaryGroups;
    "undeclared device fails" = lib.any (lib.hasInfix "abcde-12345 → stranger") (
      failedAssertions (
        evalSyncthing (
          lib.recursiveUpdate twoFolders {
            folders."abcde-12345".devices = [
              "laptop"
              "stranger"
            ];
          }
        )
      )
    );
    "malformed device id is rejected" = rejects (evalSyncthing {
      devices.laptop.id = "not-a-device-id";
    });
    "relative folder path is rejected" = rejects (evalSyncthing {
      folders.x = {
        label = "X";
        path = "sync/x";
      };
    });
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
if failed != [ ] then
  throw "syncthing-settings: failed: ${lib.concatStringsSep "; " failed}"
else
  pkgs.runCommand "syncthing-settings" { } ''
    echo ${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.attrNames checks))} > $out
  ''

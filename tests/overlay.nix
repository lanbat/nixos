# tests/overlay.nix
#
# The overlay contract. With no overlay, hosts must still resolve to something
# usable — the LAN hostname and address they already had — so that a consumer
# never has to ask whether an overlay exists before asking where a host is.
{ lib, pkgs }:

let
  evalOverlay =
    (lib.nixosSystem {
      modules = [
        ../modules/core/settings.nix
        ../modules/core/overlay.nix
        ../modules/overlay/none.nix
        {
          boot.isContainer = true;
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "25.11";
          lanbat.profile = "test";
          lanbat.hostKey = "server";
          lanbat.hosts = {
            server = {
              role = "server";
              networking = {
                ip = "192.0.2.10";
                interface = "eth0";
                hostname = "server";
              };
            };
            pi = {
              role = "storage-pi";
              networking = {
                ip = "192.0.2.11";
                interface = "eth0";
                hostname = "pi";
              };
            };
          };
        }
      ];
    }).config.lanbat.overlay;

  expect = name: cond: if cond then null else "FAIL: ${name}";

  cases = [
    (expect "provider reports itself" (evalOverlay.provider == "none"))
    (expect "a host resolves to its own hostname" (evalOverlay.nameOf "pi" == "pi"))
    (expect "a host resolves to its LAN address" (evalOverlay.addressOf "pi" == "192.0.2.11"))
    (expect "the local host resolves too" (evalOverlay.nameOf "server" == "server"))
    (expect "no host is on an overlay there is not" (!(evalOverlay.onOverlay "pi")))
    (expect "there is no interface to bind to" (evalOverlay.interface == null))
    (expect "there is no unit to order after" (evalOverlay.unit == null))
  ];

  failures = lib.filter (x: x != null) cases;
in
pkgs.runCommand "overlay-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "overlay contract checks failed:" >&2
    ${lib.concatStringsSep "\n" (map (msg: "echo \"  - ${msg}\" >&2") failures)}
    exit 1
  fi
  touch $out
''

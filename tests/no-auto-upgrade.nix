# tests/no-auto-upgrade.nix
#
# deploy-rs is the only way a host changes. No role may enable
# system.autoUpgrade: it would rebuild from a clone on the host and revert
# anything deployed that the clone lacks (see issue #77). Checks the example
# hosts CI evaluates and every role in the VM-test fixture, voice-pi included.
#
# Pure evaluation: the derivation only builds when no host enables it.
{
  lib,
  pkgs,
  inputs,
  self,
  agenix,
  disko,
  nixpkgs,
  nixos-raspberrypi,
}:

let
  fixture = import ./lib/mk-host-fixture.nix {
    inherit
      pkgs
      agenix
      inputs
      nixpkgs
      nixos-raspberrypi
      disko
      ;
  };

  hosts = {
    inherit (self.nixosConfigurations) example-server example-pi-storage;
    fixture-server = fixture.mkHostFor "server" fixture.deploy.hosts.server;
    fixture-pi-storage = fixture.piStorageSystem;
    fixture-voice-pi = fixture.voicePiSystem;
  };

  failures = lib.attrNames (lib.filterAttrs (_: host: host.config.system.autoUpgrade.enable) hosts);
in
if failures != [ ] then
  throw "system.autoUpgrade is enabled on: ${lib.concatStringsSep ", " failures}"
else
  pkgs.runCommand "no-auto-upgrade" { } ''
    echo "checked: ${lib.concatStringsSep " " (lib.attrNames hosts)}"
    touch $out
  ''

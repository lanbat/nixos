# tests/no-auto-upgrade.nix
#
# deploy-rs is the only way a host changes. No role may enable
# system.autoUpgrade: it would rebuild from a clone on the host and revert
# anything deployed that the clone lacks (see issue #77). Checks every host in
# nixosConfigurations (the example hosts in CI, a site's own hosts where its
# deploy.nix is present, as when deploy-rs checks the flake) and every role in
# the VM-test fixture, voice-pi included.
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

  hosts =
    self.nixosConfigurations
    // lib.mapAttrs' (name: lib.nameValuePair "fixture-${name}") fixture.default.systems;

  failures = lib.attrNames (lib.filterAttrs (_: host: host.config.system.autoUpgrade.enable) hosts);
in
if failures != [ ] then
  throw "system.autoUpgrade is enabled on: ${lib.concatStringsSep ", " failures}"
else
  pkgs.runCommand "no-auto-upgrade" { } ''
    echo "checked: ${lib.concatStringsSep " " (lib.attrNames hosts)}"
    touch $out
  ''

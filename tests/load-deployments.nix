# tests/load-deployments.nix
#
# Multi-profile deploy normalization and mkProfile smoke checks.
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
  loadDeployments = import ../lib/load-deployments.nix { inherit lib; };

  lanbatPlugins = import ../plugins;

  inputsWithSelf = inputs // {
    self = self // {
      inherit lanbatPlugins;
    };
  };

  fixture = import ./fixtures/multi-profile-deploy.nix {
    inputs = inputsWithSelf;
  };

  profiles = loadDeployments.normalize fixture;

  lanbatLib = import ../lib {
    self = inputsWithSelf.self;
    inputs = inputsWithSelf;
    inherit
      nixpkgs
      nixos-raspberrypi
      agenix
      disko
      deploy-rs
      profiles
      ;
  };

  inherit (lanbatLib) hostFlakeName mkProfile;

  # The modules lib/mkHost.nix puts together for a homelab host with the given
  # deploy entry changes, without evaluating the configuration.
  modulesOf =
    hostName: entry:
    let
      deploy = profiles.homelab;
    in
    (lanbatLib.mkHost "homelab" deploy hostName (deploy.hosts.${hostName} // entry) { }).lanbatModules;

  piHardware = ../hosts/pi/hardware.nix;
  # A marker module: only its place in the list is compared.
  ownHardware = {
    _file = "own-hardware";
  };

  homelabFlake = hostFlakeName "homelab" "server";
  cabinFlake = hostFlakeName "cabin" "server";

  expectMkProfile =
    profileName:
    let
      result = builtins.tryEval (mkProfile profileName profiles.${profileName});
    in
    if result.success then null else "mkProfile ${profileName} threw: ${result.value}";

  failures = lib.filter (x: x != null) [
    (
      if profiles ? homelab && profiles ? cabin then
        null
      else
        "normalize: expected homelab and cabin keys"
    )
    (
      if hostFlakeName "homelab" "server" == "homelab-server" then
        null
      else
        "hostFlakeName homelab/server mismatch"
    )
    (
      if hostFlakeName "default" "server" == "server" then
        null
      else
        "hostFlakeName default/server mismatch"
    )
    (
      if homelabFlake != cabinFlake then
        null
      else
        "hostFlakeName: homelab and cabin must produce distinct flake attrs"
    )
    (
      if lib.elem piHardware (modulesOf "pi-storage" { }) then
        null
      else
        "mkHost: a Raspberry Pi host must import hosts/pi/hardware.nix by default"
    )
    (
      let
        modules = modulesOf "pi-storage" { hardware = [ ownHardware ]; };
      in
      if lib.elem ownHardware modules && !(lib.elem piHardware modules) then
        null
      else
        "mkHost: hardware must replace hosts/pi/hardware.nix"
    )
    (
      if !(lib.elem piHardware (modulesOf "pi-storage" { hardware = [ ]; })) then
        null
      else
        "mkHost: hardware = [ ] must import no platform hardware"
    )
    (
      if
        lib.elem ../modules/wiring/caddy.nix (modulesOf "server" { })
        && !(lib.elem ../modules/wiring/caddy.nix (modulesOf "server" { roleModules.wiring-caddy = null; }))
      then
        null
      else
        "mkHost: roleModules.wiring-caddy = null must drop modules/wiring/caddy.nix"
    )
    (expectMkProfile "homelab")
    (expectMkProfile "cabin")
  ];
in
pkgs.runCommand "load-deployments-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "load-deployments tests failed:" >&2
    ${lib.concatStringsSep "\n" (map (m: "echo \"  - ${m}\" >&2") failures)}
    exit 1
  fi
  touch $out
''

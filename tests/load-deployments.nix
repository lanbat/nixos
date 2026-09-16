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

  lanbatPlugins = {
    services = import ../plugins/services;
    tv = import ../plugins/tv;
    voice = import ../plugins/voice;
  };

  inputsWithSelf = inputs // {
    self = self // { inherit lanbatPlugins; };
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

  homelabFlake = hostFlakeName "homelab" "server";
  cabinFlake = hostFlakeName "cabin" "server";

  expectMkProfile =
    profileName:
    let
      result = builtins.tryEval (mkProfile profileName profiles.${profileName});
    in
    if result.success then null else "mkProfile ${profileName} threw: ${result.value}";

  failures = lib.filter (x: x != null) [
    (if profiles ? homelab && profiles ? cabin then null else "normalize: expected homelab and cabin keys")
    (if hostFlakeName "homelab" "server" == "homelab-server" then null else "hostFlakeName homelab/server mismatch")
    (if hostFlakeName "default" "server" == "server" then null else "hostFlakeName default/server mismatch")
    (if homelabFlake != cabinFlake then null else "hostFlakeName: homelab and cabin must produce distinct flake attrs")
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

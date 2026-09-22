# tests/deploy-rs-fixture.nix
#
# Build deployChecks from a fixture profile, independent of ./deploy.nix.
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

  serverNodes = lib.filterAttrs (n: _: n == "homelab-server") lanbatLib.deployNodes;

  checks =
    if serverNodes ? homelab-server then
      (lanbatLib.deployLib "x86_64-linux").deployChecks { nodes = serverNodes; }
    else
      throw "expected homelab-server deploy node";
in
pkgs.runCommand "deploy-rs-fixture"
  {
    nativeBuildInputs = [
      checks.deploy-activate
      checks.deploy-schema
    ];
  }
  ''
    touch $out
  ''

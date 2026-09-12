# tests/assertions.nix
#
# Checks that modules/wiring/checks.nix rejects broken service descriptions
# and accepts a valid one. Pure evaluation: the derivation only builds when
# every case produced the expected messages.
{ lib, pkgs }:

let
  evalServices =
    services:
    let
      system = lib.nixosSystem {
        modules = [
          ../modules/core/services.nix
          ../modules/wiring/accounts.nix
          {
            boot.isContainer = true;
            nixpkgs.hostPlatform = "x86_64-linux";
            system.stateVersion = "25.11";
            lanbat.services = services;
            systemd.services.demo.script = "true";
          }
        ];
      };
      checks = import ../modules/wiring/checks.nix {
        inherit lib;
        inherit (system) config;
      };
    in
    map (a: a.message) (lib.filter (a: !a.assertion) checks.assertions);

  expect =
    name: services: fragments:
    let
      messages = evalServices services;
      missing = lib.filter (f: !lib.any (lib.hasInfix f) messages) fragments;
      unexpected = fragments == [ ] && messages != [ ];
    in
    if missing != [ ] || unexpected then
      throw "assertion test '${name}' failed: expected ${builtins.toJSON fragments}, got ${builtins.toJSON messages}"
    else
      name;

  results = [
    (expect "valid service passes" {
      demo = {
        subdomain = "demo";
        port = 8000;
        tier = "workload";
        state = [ "demo" ];
        units = [ "demo" ];
      };
    } [ ])

    (expect "port clash" {
      a.port = 8080;
      b.extraPorts = [ 8080 ];
    } [ "port 8080 is used by a, b" ])

    (expect "subdomain clash" {
      a = {
        subdomain = "x";
        port = 1;
      };
      b = {
        subdomain = "x";
        port = 2;
      };
    } [ "subdomain x is used by a, b" ])

    (expect "UID clash" {
      a.account.uid = 950;
      b.account.uid = 950;
    } [ "UID 950 is used by a, b" ])

    (expect "forward auth on a service with API clients" {
      authentik.port = 9000;
      app = {
        subdomain = "app";
        port = 1234;
        auth = "forward-auth";
        apiClients = true;
      };
    } [ "app has API clients, so it can't use forward auth" ])

    (expect "workload tier without state" {
      demo = {
        tier = "workload";
        units = [ "demo" ];
      };
    } [ "demo is workload-gated but declares no state" ])

    (expect "state without workload tier" {
      demo.state = [ "demo" ];
    } [ "declares state or workloadDirs but isn't workload-gated" ])

    (expect "unit that no module defines" {
      demo = {
        tier = "workload";
        state = [ "demo" ];
        units = [ "no-such-unit" ];
      };
    } [ "references unit no-such-unit, which no module defines" ])

    (expect "on-demand without a port" {
      demo = {
        units = [ "demo" ];
        onDemand.activatorPort = 3000;
      };
    } [ "demo is on-demand but has no port" ])

    (expect "dashboard without subdomain" {
      demo.dashboard = {
        group = "G";
        name = "Demo";
        description = "d";
      };
    } [ "demo is on the dashboard but has no subdomain" ])
  ];
in
pkgs.runCommand "lanbat-assertions" { } ''
  echo ${lib.escapeShellArg (lib.concatStringsSep "\n" results)}
  touch $out
''

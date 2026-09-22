# tests/policy.nix
#
# Generated firewall policy: a service port admits exactly the hosts running a
# service that declared it consumes that service, and nothing else.
{ lib, pkgs }:

let
  evalPolicy =
    { services, endpoints }:
    (lib.nixosSystem {
      modules = [
        ../modules/core/settings.nix
        ../modules/core/services.nix
        ../modules/wiring/policy.nix
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
          lanbat.services = services;
          lanbat.endpoints = endpoints;
        }
      ];
    }).config.networking.firewall.extraCommands;

  withRemoteConsumer = evalPolicy {
    services.mosquitto.endpoint = {
      scheme = "mqtt";
      port = 1883;
    };
    endpoints = {
      mosquitto = {
        hosts = [ "server" ];
        consumes = [ ];
      };
      telegraf = {
        hosts = [ "pi" ];
        consumes = [ "mosquitto" ];
      };
    };
  };

  # Tang publishes no endpoint, so nothing may be generated for it. This is the
  # property that keeps the Pi's LUKS unlock working.
  tangUntouched = evalPolicy {
    services.tang.extraPorts = [ 7500 ];
    endpoints.tang = {
      hosts = [ "server" ];
      consumes = [ ];
    };
  };

  expect = name: cond: if cond then null else "FAIL: ${name}";

  cases = [
    (expect "a remote consumer's host is accepted" (
      lib.hasInfix "--dport 1883 -s 192.0.2.11 -j ACCEPT" withRemoteConsumer
    ))
    (expect "loopback is exempt from the drop" (lib.hasInfix "! -i lo" withRemoteConsumer))
    (expect "a service with no endpoint generates nothing" (!(lib.hasInfix "7500" tangUntouched)))
  ];

  failures = lib.filter (x: x != null) cases;
in
pkgs.runCommand "policy-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "policy checks failed:" >&2
    ${lib.concatStringsSep "\n" (map (msg: "echo \"  - ${msg}\" >&2") failures)}
    exit 1
  fi
  touch $out
''

# tests/endpoints-table.nix
#
# The profile-wide table must carry what each service consumes, not only what
# it publishes, because policy is generated on the provider's host from
# consumers that may live on another one.
{ lib, pkgs }:

let
  endpointLib = import ../lib/endpoints.nix { inherit lib; };

  hosts = {
    server.networking = {
      ip = "192.0.2.10";
      hostname = "server";
    };
    pi.networking = {
      ip = "192.0.2.11";
      hostname = "pi";
    };
  };

  described = {
    server.mosquitto = {
      endpoint = {
        scheme = "mqtt";
        port = 1883;
      };
      account = null;
      consumes = [ ];
    };
    pi.telegraf = {
      endpoint = null;
      account = null;
      consumes = [ "mosquitto" ];
    };
  };

  table = endpointLib.mkTable {
    profileName = "test";
    inherit described hosts;
  };

  expect = name: cond: if cond then null else "FAIL: ${name}";

  cases = [
    (expect "a consumer's consumes list reaches the table" (table.telegraf.consumes == [ "mosquitto" ]))
    (expect "a service that consumes nothing gets an empty list" (table.mosquitto.consumes == [ ]))
  ];

  failures = lib.filter (x: x != null) cases;
in
pkgs.runCommand "endpoints-table-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "endpoint table checks failed:" >&2
    ${lib.concatStringsSep "\n" (map (msg: "echo \"  - ${msg}\" >&2") failures)}
    exit 1
  fi
  touch $out
''

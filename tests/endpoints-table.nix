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
      nfs = {
        drives = [ ];
        storageHost = null;
      };
    };
    server.jellyfin = {
      endpoint = null;
      account = null;
      consumes = [ ];
      nfs = {
        drives = [ "a" ];
        storageHost = null;
      };
    };
    pi.telegraf = {
      endpoint = null;
      account = null;
      consumes = [ "mosquitto" ];
      nfs = {
        drives = [ ];
        storageHost = null;
      };
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
    (expect "the drives a service uses reach the table" (table.jellyfin.nfs.drives == [ "a" ]))
    (expect "the hosts using a storage host's drives are its NFS clients" (
      endpointLib.nfsClientsOf {
        endpoints = table;
        storageHost = "pi";
        primaryStorage = "pi";
      } == [ "server" ]
    ))
    (expect "a storage host nobody names has no NFS clients" (
      endpointLib.nfsClientsOf {
        endpoints = table;
        storageHost = "pi";
        primaryStorage = "other-pi";
      } == [ ]
    ))
    (expect "the one host running a service is found" (
      endpointLib.soleHost {
        endpoints = table;
        name = "mosquitto";
        consumer = "test";
      } == "server"
    ))
    (expect "a service that runs nowhere is an error, not a guess" (
      !(builtins.tryEval (
        endpointLib.soleHost {
          endpoints = table;
          name = "absent";
          consumer = "test";
        }
      )).success
    ))
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

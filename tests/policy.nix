# tests/policy.nix
#
# Generated firewall policy: a service port admits exactly the hosts running a
# service that declared it consumes that service, and nothing else.
{ lib, pkgs }:

let
  lanHosts = {
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

  # The same two hosts on a mesh, and a third that stays off it.
  meshHosts = lib.recursiveUpdate lanHosts {
    server.overlay = {
      ip = "10.100.0.1";
      publicKey = "server-public-key";
      endpoint = "192.0.2.10:51820";
    };
    pi.overlay = {
      ip = "10.100.0.2";
      publicKey = "pi-public-key";
    };
  };
  meshHostsWithOutsider = meshHosts // {
    voice = {
      role = "voice-pi";
      networking = {
        ip = "192.0.2.12";
        interface = "eth0";
        hostname = "voice";
      };
    };
  };

  evalHost =
    {
      services,
      endpoints,
      hostKey ? "server",
      provider ? "none",
      hosts ? lanHosts,
    }:
    (lib.nixosSystem {
      modules = [
        ../modules/core/settings.nix
        ../modules/core/services.nix
        ../modules/core/overlay.nix
        ../modules/wiring/secrets.nix
        ../modules/wiring/policy.nix
        (import ../lib/overlay-providers.nix).${provider}
        ./lib/age-option-stub.nix
        {
          boot.isContainer = true;
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "25.11";
          lanbat.profile = "test";
          lanbat.hostKey = hostKey;
          lanbat.deployment.overlay = {
            inherit provider;
          }
          // lib.optionalAttrs (provider != "none") {
            subnet = "10.100.0.0/24";
            domain = "mesh.test";
          };
          lanbat.deployment.secrets = {
            provider = "none";
            root = ../secrets;
          };
          lanbat.hosts = hosts;
          lanbat.services = services;
          lanbat.endpoints = endpoints;
        }
      ];
    }).config;

  evalPolicy = args: (evalHost args).networking.firewall.extraCommands;

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

  # A third service exists in the profile but consumes something else, so it
  # must not be admitted to mosquitto's port.
  withBystander = evalPolicy {
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
      bystander = {
        hosts = [ "pi" ];
        consumes = [ "something-else" ];
      };
    };
  };

  # A consumer on the same host needs no rule: the traffic never leaves it.
  localConsumerOnly = evalPolicy {
    services.mosquitto.endpoint = {
      scheme = "mqtt";
      port = 1883;
    };
    endpoints = {
      mosquitto = {
        hosts = [ "server" ];
        consumes = [ ];
      };
      frigate = {
        hosts = [ "server" ];
        consumes = [ "mosquitto" ];
      };
    };
  };

  # Mosquitto on the server, consumed from the pi, under a mesh. Endpoints
  # must agree across hosts, so the table carries the same transport the
  # service module would default to.
  meshMosquitto =
    {
      transport ? "overlay",
      hosts ? meshHosts,
      extraEndpoints ? { },
    }:
    let
      endpoint = {
        scheme = "mqtt";
        port = 1883;
        inherit transport;
      };
      endpoints = {
        mosquitto = {
          hosts = [ "server" ];
          consumes = [ ];
          inherit endpoint;
        };
        telegraf = {
          hosts = [ "pi" ];
          consumes = [ "mosquitto" ];
          endpoint = null;
        };
      }
      // extraEndpoints;
    in
    {
      server = evalHost {
        provider = "wireguard-mesh";
        inherit hosts endpoints;
        services.mosquitto.endpoint = endpoint;
      };
      pi = evalHost {
        provider = "wireguard-mesh";
        hostKey = "pi";
        inherit hosts endpoints;
        services = { };
      };
    };

  overOverlay = meshMosquitto { };
  pinnedToLan = meshMosquitto { transport = "lan"; };
  # A third host consuming mosquitto, added to the profile with no firewall
  # edit: it is off the overlay, so it is admitted at its LAN address.
  withOutsider = meshMosquitto {
    hosts = meshHostsWithOutsider;
    extraEndpoints.recorder = {
      hosts = [ "voice" ];
      consumes = [ "mosquitto" ];
      endpoint = null;
    };
  };

  # Tang under a mesh: still no endpoint, still nothing generated.
  tangOnMesh = evalPolicy {
    provider = "wireguard-mesh";
    hosts = meshHosts;
    services.tang.extraPorts = [ 7500 ];
    endpoints.tang = {
      hosts = [ "server" ];
      consumes = [ ];
    };
  };

  # NFS under a mesh: the storage Pi exports to the server's LAN address, not
  # its overlay address, because the server mounts over the LAN and Pi storage
  # must not depend on the overlay.
  nfsOnMesh = import ../lib/nfs-clients.nix {
    inherit lib;
    config = evalHost {
      provider = "wireguard-mesh";
      hostKey = "pi";
      hosts = meshHosts;
      services = { };
      endpoints.jellyfin = {
        hosts = [ "server" ];
        consumes = [ ];
        endpoint = null;
        nfs = {
          drives = [ "a" ];
          storageHost = "pi";
        };
      };
    };
  };

  rulesOf = cfg: cfg.networking.firewall.extraCommands;

  expect = name: cond: if cond then null else "FAIL: ${name}";

  cases = [
    (expect "NFS is exported to the LAN address under a mesh" (nfsOnMesh.addresses == [ "192.0.2.10" ]))
    (expect "a remote consumer's host is accepted" (
      lib.hasInfix "--dport 1883 -s 192.0.2.11 -j ACCEPT" withRemoteConsumer
    ))
    (expect "loopback is exempt from the drop" (lib.hasInfix "! -i lo" withRemoteConsumer))
    (expect "a service with no endpoint generates nothing" (!(lib.hasInfix "7500" tangUntouched)))

    (expect "a port whose only consumer is local gets a drop and no accept" (
      lib.hasInfix "--dport 1883 ! -i lo -j DROP" localConsumerOnly
      && !(lib.hasInfix "-j ACCEPT" localConsumerOnly)
    ))

    (expect "a service consuming something else is not admitted" (
      lib.count (x: x == "-s") (lib.splitString " " withBystander) == 1
    ))

    (expect "mesh: an overlay edge admits the consumer's overlay address on the overlay" (
      lib.hasInfix "--dport 1883 -s 10.100.0.2 -i lanbat0 -j ACCEPT" (rulesOf overOverlay.server)
    ))
    (expect "mesh: an overlay edge no longer admits the LAN address" (
      !(lib.hasInfix "192.0.2.11" (rulesOf overOverlay.server))
    ))
    (expect "mesh: the overlay edge's rule is removed on stop too" (
      lib.hasInfix "iptables -D INPUT -p tcp --dport 1883 -s 10.100.0.2 -i lanbat0 -j ACCEPT" overOverlay.server.networking.firewall.extraStopCommands
    ))
    (expect "mesh: the consumer dials the overlay name" (
      overOverlay.pi.lanbat.endpointHost "mosquitto" "server" == "server.mesh.test"
    ))
    (expect "mesh: an edge pinned to the LAN stays on the LAN address" (
      lib.hasInfix "--dport 1883 -s 192.0.2.11 -j ACCEPT" (rulesOf pinnedToLan.server)
      && !(lib.hasInfix "lanbat0" (rulesOf pinnedToLan.server))
    ))
    (expect "mesh: the consumer of a LAN-pinned edge dials the LAN address" (
      pinnedToLan.pi.lanbat.endpointHost "mosquitto" "server" == "192.0.2.10"
    ))
    (expect "mesh: a new consumer host is admitted without any firewall edit" (
      lib.hasInfix "--dport 1883 -s 10.100.0.2 -i lanbat0 -j ACCEPT" (rulesOf withOutsider.server)
      && lib.hasInfix "--dport 1883 -s 192.0.2.12 -j ACCEPT" (rulesOf withOutsider.server)
    ))
    (expect "mesh: a service with no endpoint, such as Tang, generates nothing" (
      !(lib.hasInfix "7500" tangOnMesh)
    ))
    (expect "no overlay: consumers dial the LAN address" (
      (evalHost {
        hostKey = "pi";
        services = { };
        endpoints.mosquitto = {
          hosts = [ "server" ];
          consumes = [ ];
          endpoint = {
            scheme = "mqtt";
            port = 1883;
            transport = "lan";
          };
        };
      }).lanbat.endpointHost
        "mosquitto"
        "server" == "192.0.2.10"
    ))
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

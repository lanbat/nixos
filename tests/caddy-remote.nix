# tests/caddy-remote.nix
#
# Caddy serving the subdomain of a service that runs on another host.
#
# Pure evaluation of a two-host profile, built the way lib/default.nix builds
# one: each host's descriptions first, then the profile-wide table from them
# (lib/endpoints.nix), then the hosts with the table. The server runs Caddy and
# an authentication provider; the Pi runs a web service with a subdomain.
#
#   - the server's vhost proxies to the Pi's LAN address at the endpoint port,
#     and a local service keeps localhost;
#   - the Pi's generated policy admits the server to that port, with no
#     consumes list naming it;
#   - under a mesh, the vhost uses the Pi's overlay name and the Pi admits the
#     server's overlay address on the overlay interface;
#   - forward auth still wraps the remote vhost, and the Authentik catalogue on
#     the server lists the remote service;
#   - a copy of the service on the Caddy host wins, and the Pi admits nothing;
#   - remote on-demand, no endpoint, several hosts, a non-HTTP scheme, a
#     localhost reference and a subdomain clash are evaluation errors.
{ lib, pkgs }:

let
  endpointLib = import ../lib/endpoints.nix { inherit lib; };

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
    pi2 = {
      role = "storage-pi";
      networking = {
        ip = "192.0.2.12";
        interface = "eth0";
        hostname = "pi2";
      };
    };
  };

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

  # What the server runs in every case: Caddy, a stand-in authentication
  # provider, Authentik's description (for its catalogue) and a local web
  # service.
  serverServices = {
    caddy = {
      subdomain = "ca";
      auth = "none";
      caddy.extraConfig = "file_server";
    };
    authentik = {
      subdomain = "auth";
      port = 9000;
    };
    local = {
      subdomain = "local";
      port = 8001;
    };
  };

  demo = {
    subdomain = "demo";
    port = 8123;
    auth = "forward-auth";
    dashboard = {
      group = "Utilities";
      name = "Demo";
      description = "Test service";
    };
  };

  evalHost =
    {
      hostKey,
      services,
      endpoints,
      provider,
      hosts,
    }:
    (lib.nixosSystem {
      modules = [
        ../modules/core/settings.nix
        ../modules/core/services.nix
        ../modules/core/auth.nix
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
          lanbat.deployment.domain = "home.test";
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
      ]
      # The server role's wiring, as lib/roles.nix gives it only to servers.
      ++ lib.optionals (hostKey == "server") [
        ../modules/wiring/caddy.nix
        ../services/authentik/blueprints.nix
        {
          lanbat.authProvider = {
            service = "stub";
            outpostProxy = "reverse_proxy /outpost/* localhost:9000";
            forwardAuth = "forward_auth localhost:9000";
          };
          age.secrets.authentik-oidc-secrets = { };
        }
      ];
    }).config;

  # Both passes of lib/default.nix over `placement` (host -> its services).
  profile =
    {
      placement,
      provider ? "none",
      hosts ? lanHosts,
    }:
    let
      evalWith =
        endpoints: hostKey: services:
        evalHost {
          inherit
            hostKey
            services
            endpoints
            provider
            hosts
            ;
        };
      described = lib.mapAttrs (
        hostKey: services: (evalWith { } hostKey services).lanbat.services
      ) placement;
      endpoints = endpointLib.mkTable {
        profileName = "test";
        inherit described hosts;
      };
    in
    lib.mapAttrs (evalWith endpoints) placement;

  vhost = cfg: sub: cfg.services.caddy.virtualHosts."${sub}.home.test".extraConfig;
  rulesOf = cfg: cfg.networking.firewall.extraCommands;
  lanbatErrors =
    cfg:
    map (a: a.message) (
      lib.filter (a: !a.assertion && lib.hasPrefix "lanbat:" a.message) cfg.assertions
    );
  hasError = cfg: needle: lib.any (lib.hasInfix needle) (lanbatErrors cfg);

  onPi = profile {
    placement = {
      server = serverServices;
      pi.demo = demo;
    };
  };

  onMesh = profile {
    provider = "wireguard-mesh";
    hosts = meshHosts;
    placement = {
      server = serverServices;
      pi.demo = demo;
    };
  };

  # Pinned to the LAN under a mesh: both ends stay on the LAN address.
  pinnedToLan = profile {
    provider = "wireguard-mesh";
    hosts = meshHosts;
    placement = {
      server = serverServices;
      pi.demo = demo // {
        endpoint = {
          port = 8123;
          transport = "lan";
        };
      };
    };
  };

  onBoth = profile {
    placement = {
      server = serverServices // {
        inherit demo;
      };
      pi.demo = demo;
    };
  };

  withoutSubdomain = profile {
    placement = {
      server = serverServices;
      pi.demo = removeAttrs demo [
        "subdomain"
        "dashboard"
      ];
    };
  };

  broken =
    piDemo:
    (profile {
      placement = {
        server = serverServices;
        pi.demo = piDemo;
      };
    }).server;

  onDemandRemote = broken (
    demo
    // {
      units = [ "demo" ];
      onDemand.activatorPort = 8124;
    }
  );
  noEndpoint = broken (demo // { endpoint = null; });
  mqttScheme = broken (
    demo
    // {
      endpoint = {
        scheme = "mqtt";
        port = 8123;
      };
    }
  );
  httpsScheme = broken (
    demo
    // {
      endpoint = {
        scheme = "https";
        port = 8443;
      };
    }
  );
  localhostRef = broken (
    demo
    // {
      caddy.extraConfig = ''
        handle /ws {
          reverse_proxy localhost:3012
        }
      '';
    }
  );
  clash = broken (demo // { subdomain = "local"; });

  onTwoPis =
    (profile {
      placement = {
        server = serverServices;
        pi.demo = demo;
        pi2.demo = demo;
      };
    }).server;

  catalogue = onPi.server.lanbat.authentik.blueprints;
  proxyIds = map (e: e.id) (
    lib.filter (e: e.model == "authentik_providers_proxy.proxyprovider") catalogue.proxy.entries
  );

  expect = name: cond: if cond then null else "FAIL: ${name}";

  cases = [
    (expect "the remote vhost proxies to the Pi's LAN address at the endpoint port" (
      lib.hasInfix "reverse_proxy 192.0.2.11:8123" (vhost onPi.server "demo")
    ))
    (expect "the remote vhost does not proxy to localhost" (
      !(lib.hasInfix "reverse_proxy localhost:8123" (vhost onPi.server "demo"))
    ))
    (expect "a local service keeps localhost" (
      lib.hasInfix "reverse_proxy localhost:8001" (vhost onPi.server "local")
    ))
    (expect "forward auth still wraps the remote vhost" (
      lib.hasInfix "forward_auth localhost:9000" (vhost onPi.server "demo")
      && lib.hasInfix "reverse_proxy /outpost/* localhost:9000" (vhost onPi.server "demo")
    ))
    (expect "the Pi admits the server, which consumes nothing by name" (
      lib.hasInfix "--dport 8123 -s 192.0.2.10 -j ACCEPT" (rulesOf onPi.pi)
    ))
    (expect "the Pi still drops everyone else on that port" (
      lib.hasInfix "--dport 8123 ! -i lo -j DROP" (rulesOf onPi.pi)
    ))
    (expect "a valid profile raises no lanbat errors" (
      lanbatErrors onPi.server == [ ] && lanbatErrors onMesh.server == [ ]
    ))
    (expect "the Authentik catalogue on the server lists the remote service" (
      lib.elem "provider-demo" proxyIds
    ))
    (expect "the embedded outpost serves the remote service" (
      lib.any (p: p.value == "provider-demo")
        (lib.head (lib.filter (e: e.model == "authentik_outposts.outpost") catalogue.proxy.entries))
        .attrs.providers
    ))

    (expect "mesh: the remote vhost uses the Pi's overlay name" (
      lib.hasInfix "reverse_proxy pi.mesh.test:8123" (vhost onMesh.server "demo")
    ))
    (expect "mesh: the Pi admits the server's overlay address on the overlay" (
      lib.hasInfix "--dport 8123 -s 10.100.0.1 -i lanbat0 -j ACCEPT" (rulesOf onMesh.pi)
      && !(lib.hasInfix "192.0.2.10" (rulesOf onMesh.pi))
    ))
    (expect "mesh: an endpoint pinned to the LAN is proxied and admitted on the LAN" (
      lib.hasInfix "reverse_proxy 192.0.2.11:8123" (vhost pinnedToLan.server "demo")
      && lib.hasInfix "--dport 8123 -s 192.0.2.10 -j ACCEPT" (rulesOf pinnedToLan.pi)
    ))

    (expect "a copy on the Caddy host wins" (
      lib.hasInfix "reverse_proxy localhost:8123" (vhost onBoth.server "demo")
      && !(lib.hasInfix "192.0.2.11" (vhost onBoth.server "demo"))
    ))
    (expect "a copy on the Caddy host means the other host admits no one" (
      !(lib.hasInfix "-j ACCEPT" (rulesOf onBoth.pi))
    ))
    (expect "a remote service without a subdomain gets no vhost and no admission" (
      !(withoutSubdomain.server.services.caddy.virtualHosts ? "demo.home.test")
      && !(lib.hasInfix "-j ACCEPT" (rulesOf withoutSubdomain.pi))
    ))
    (expect "an https endpoint is proxied over https" (
      lib.hasInfix "reverse_proxy https://192.0.2.11:8443" (vhost httpsScheme "demo")
    ))

    (expect "remote on-demand is rejected" (hasError onDemandRemote "demo is on-demand and runs on pi"))
    (expect "remote on-demand gets no vhost" (
      !(onDemandRemote.services.caddy.virtualHosts ? "demo.home.test")
    ))
    (expect "a remote service without an endpoint is rejected" (
      hasError noEndpoint "publishes no endpoint"
    ))
    (expect "a non-HTTP endpoint is rejected" (hasError mqttScheme "uses scheme \"mqtt\""))
    (expect "a localhost reference in a remote service's Caddy config is rejected" (
      hasError localhostRef "refers to localhost"
    ))
    (expect "a remote subdomain clashing with a local one is rejected" (
      hasError clash "subdomain local is used by"
    ))
    (expect "a subdomain service on several remote hosts is rejected" (
      hasError onTwoPis "runs on more than one host (pi, pi2)"
    ))
  ];

  failures = lib.filter (x: x != null) cases;
in
pkgs.runCommand "caddy-remote-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "caddy remote checks failed:" >&2
    ${lib.concatStringsSep "\n" (map (msg: "echo \"  - ${msg}\" >&2") failures)}
    exit 1
  fi
  touch $out
''

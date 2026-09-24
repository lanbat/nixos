# tests/overlay.nix
#
# The overlay contract. With no overlay, hosts must still resolve to something
# usable — the LAN hostname and address they already had — so that a consumer
# never has to ask whether an overlay exists before asking where a host is.
{ lib, pkgs }:

let
  evalOverlay =
    (lib.nixosSystem {
      modules = [
        ../modules/core/settings.nix
        ../modules/core/overlay.nix
        ../modules/overlay/none.nix
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
        }
      ];
    }).config.lanbat.overlay;

  # Endpoint transport under a given provider. Only the schema is evaluated,
  # so the provider need not exist — the default reads the name alone.
  transportsUnder =
    provider:
    lib.mapAttrs (_: svc: svc.endpoint.transport)
      (lib.nixosSystem {
        modules = [
          ../modules/core/settings.nix
          ../modules/core/services.nix
          {
            boot.isContainer = true;
            nixpkgs.hostPlatform = "x86_64-linux";
            system.stateVersion = "25.11";
            lanbat.deployment.overlay.provider = provider;
            lanbat.services = {
              web.port = 8080;
              pinned.endpoint = {
                port = 9000;
                transport = "lan";
              };
            };
          }
        ];
      }).config.lanbat.services;

  # A three-host mesh: server can be dialled, pi dials out, voice stays off.
  meshHosts = {
    server = {
      role = "server";
      networking = {
        ip = "192.0.2.10";
        interface = "eth0";
        hostname = "server";
      };
      overlay = {
        ip = "10.100.0.1";
        publicKey = "server-public-key";
        endpoint = "192.0.2.10:51820";
      };
    };
    pi = {
      role = "storage-pi";
      networking = {
        ip = "192.0.2.11";
        interface = "eth0";
        hostname = "pi5";
      };
      overlay = {
        ip = "10.100.0.2";
        publicKey = "pi-public-key";
      };
    };
    voice = {
      role = "voice-pi";
      networking = {
        ip = "192.0.2.12";
        interface = "eth0";
        hostname = "voice";
      };
    };
  };

  evalMesh =
    hostKey:
    (lib.nixosSystem {
      modules = [
        ../modules/core/settings.nix
        ../modules/core/overlay.nix
        ../modules/core/services.nix
        ../modules/wiring/secrets.nix
        ../modules/overlay/wireguard-mesh.nix
        ./lib/age-option-stub.nix
        {
          boot.isContainer = true;
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "25.11";
          lanbat.profile = "test";
          lanbat.hostKey = hostKey;
          # As every role sets it; the netdev files are only rendered with it.
          systemd.network.enable = true;
          lanbat.deployment.overlay = {
            provider = "wireguard-mesh";
            subnet = "10.100.0.0/24";
            domain = "mesh.test";
          };
          lanbat.deployment.secrets = {
            provider = "none";
            root = ../secrets;
          };
          lanbat.hosts = meshHosts;
        }
      ];
    }).config;

  meshServer = evalMesh "server";
  meshPi = evalMesh "pi";
  meshVoice = evalMesh "voice";

  peersOf = cfg: cfg.systemd.network.netdevs."40-lanbat0".wireguardPeers;
  serverPeers = peersOf meshServer;
  piPeers = peersOf meshPi;
  serverKey = meshServer.age.secrets.overlay-server;

  noOverlay = transportsUnder "none";
  mesh = transportsUnder "wireguard-mesh";

  expect = name: cond: if cond then null else "FAIL: ${name}";

  cases = [
    (expect "provider reports itself" (evalOverlay.provider == "none"))
    (expect "a host resolves to its own hostname" (evalOverlay.nameOf "pi" == "pi"))
    (expect "a host resolves to its LAN address" (evalOverlay.addressOf "pi" == "192.0.2.11"))
    (expect "the local host resolves too" (evalOverlay.nameOf "server" == "server"))
    (expect "no host is on an overlay there is not" (!(evalOverlay.onOverlay "pi")))
    (expect "there is no interface to bind to" (evalOverlay.interface == null))
    (expect "there is no unit to order after" (evalOverlay.unit == null))
    (expect "without an overlay an endpoint stays on the LAN" (noOverlay.web == "lan"))
    (expect "with an overlay an endpoint moves onto it" (mesh.web == "overlay"))
    (expect "an endpoint pinned to the LAN stays there" (mesh.pinned == "lan"))

    (expect "mesh: one peer per other member" (lib.length serverPeers == 1 && lib.length piPeers == 1))
    (expect "mesh: no peer entry for the host itself" (
      !(lib.any (p: p.PublicKey == "server-public-key") serverPeers)
      && !(lib.any (p: p.PublicKey == "pi-public-key") piPeers)
    ))
    (expect "mesh: a host off the overlay is no peer" (
      lib.all (p: p.PublicKey != null) serverPeers && lib.length serverPeers == 1
    ))
    (expect "mesh: a peer's AllowedIPs is exactly its overlay address" (
      (lib.head serverPeers).AllowedIPs == [ "10.100.0.2/32" ]
      && (lib.head piPeers).AllowedIPs == [ "10.100.0.1/32" ]
    ))
    (expect "mesh: keepalive and endpoint toward a peer that has an endpoint" (
      (lib.head piPeers).PersistentKeepalive or null == 25
      && (lib.head piPeers).Endpoint or null == "192.0.2.10:51820"
    ))
    (expect "mesh: no keepalive toward a peer without an endpoint" (
      !((lib.head serverPeers) ? PersistentKeepalive) && !((lib.head serverPeers) ? Endpoint)
    ))
    (expect "mesh: the interface holds the host's address in the subnet" (
      meshPi.systemd.network.networks."40-lanbat0".address == [ "10.100.0.2/24" ]
    ))
    (expect "mesh: booting does not wait for the overlay" (
      meshServer.systemd.network.networks."40-lanbat0".linkConfig.RequiredForOnline == "no"
    ))
    (expect "mesh: the private key is readable by networkd and nobody else" (
      serverKey.owner == "root" && serverKey.group == "systemd-network" && serverKey.mode == "0440"
    ))
    (expect "mesh: the netdev reads the host's own key" (
      meshServer.systemd.network.netdevs."40-lanbat0".wireguardConfig.PrivateKeyFile == serverKey.path
    ))
    (expect "mesh: names are hostname.domain" (
      meshServer.lanbat.overlay.nameOf "pi" == "pi5.mesh.test"
    ))
    (expect "mesh: every member is in networking.hosts at its overlay address" (
      meshServer.networking.hosts."10.100.0.1" or [ ] == [ "server.mesh.test" ]
      && meshServer.networking.hosts."10.100.0.2" or [ ] == [ "pi5.mesh.test" ]
    ))
    (expect "mesh: a host off the overlay is not in networking.hosts" (
      !(lib.any (names: lib.elem "voice.mesh.test" names) (lib.attrValues meshServer.networking.hosts))
    ))
    (expect "mesh: a host off the overlay resolves to its LAN address" (
      meshServer.lanbat.overlay.addressOf "voice" == "192.0.2.12"
      && !(meshServer.lanbat.overlay.onOverlay "voice")
    ))
    (expect "mesh: a member resolves to its overlay address" (
      meshVoice.lanbat.overlay.addressOf "server" == "10.100.0.1"
    ))
    (expect "mesh: a host off the overlay gets no interface, key or port" (
      meshVoice.lanbat.overlay.interface == null
      && !(meshVoice.systemd.network.netdevs ? "40-lanbat0")
      && !(meshVoice.age.secrets ? overlay-voice)
      && !(lib.elem 51820 meshVoice.networking.firewall.allowedUDPPorts)
    ))
    (expect "mesh: a member opens the WireGuard port" (
      lib.elem 51820 meshPi.networking.firewall.allowedUDPPorts
    ))
    (expect "mesh: networkd gets one peer section per peer" (
      let
        text = meshPi.systemd.network.units."40-lanbat0.netdev".text;
      in
      lib.length (lib.splitString "[WireGuardPeer]" text) == 2
      && lib.hasInfix "PersistentKeepalive=25" text
      && lib.hasInfix "Endpoint=192.0.2.10:51820" text
    ))
    (expect "mesh: members have a unit to order after" (
      meshPi.lanbat.overlay.unit == "systemd-networkd-wait-online@lanbat0.service"
    ))
  ];

  failures = lib.filter (x: x != null) cases;
in
pkgs.runCommand "overlay-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "overlay contract checks failed:" >&2
    ${lib.concatStringsSep "\n" (map (msg: "echo \"  - ${msg}\" >&2") failures)}
    exit 1
  fi
  touch $out
''

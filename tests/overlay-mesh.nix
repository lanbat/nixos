# tests/overlay-mesh.nix
#
# VM test of the wireguard-mesh overlay provider with two hosts.
#
# a declares an endpoint and b does not, so b dials a and keeps the path
# open: the rendezvous case. a publishes one service, demo, which b consumes
# over the overlay, and also listens on a port no endpoint declares.
#
# Asserts that the interface comes up on both with the key agenix decrypted,
# that each reaches the other's overlay address and name, that the declared
# port is reachable across the overlay, and that the undeclared port, and the
# declared one over the LAN, are not.
#
# Run with: nix build -L .#checks.x86_64-linux.overlay-mesh
{ pkgs, agenix }:

let
  inherit (pkgs) lib;

  # The throwaway keys nixpkgs' own WireGuard tests use.
  snakeoil = import "${pkgs.path}/nixos/tests/wireguard/snakeoil-keys.nix";

  hosts = {
    a = {
      role = "server";
      networking = {
        ip = "192.168.1.1";
        interface = "eth1";
        hostname = "a";
      };
      overlay = {
        ip = "10.100.0.1";
        publicKey = lib.trim snakeoil.peer0.publicKey;
        endpoint = "192.168.1.1:51820";
      };
    };
    b = {
      role = "storage-pi";
      networking = {
        ip = "192.168.1.2";
        interface = "eth1";
        hostname = "b";
      };
      overlay = {
        ip = "10.100.0.2";
        publicKey = lib.trim snakeoil.peer1.publicKey;
      };
    };
  };

  demoEndpoint = {
    scheme = "http";
    port = 8000;
    transport = "overlay";
  };

  # The profile-wide table lib/endpoints.nix would build: demo on a, consumed
  # by a service on b.
  endpoints = {
    demo = {
      hosts = [ "a" ];
      consumes = [ ];
      endpoint = demoEndpoint;
      account = null;
    };
    client = {
      hosts = [ "b" ];
      consumes = [ "demo" ];
      endpoint = null;
      account = null;
    };
  };

  httpServer = port: {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      DynamicUser = true;
      ExecStart = "${pkgs.python3}/bin/python3 -m http.server ${toString port} --bind 0.0.0.0 --directory ${pkgs.writeTextDir "index.html" "hello"}";
    };
  };

  node =
    hostKey: privateKey: extra:
    { pkgs, ... }:
    {
      imports = [
        agenix.nixosModules.default
        ../modules/core/settings.nix
        ../modules/core/services.nix
        ../modules/core/overlay.nix
        ../modules/wiring/secrets.nix
        ../modules/wiring/policy.nix
        ../modules/overlay/wireguard-mesh.nix
        ./lib/test-secrets.nix
        extra
      ];

      # As every role sets it.
      networking.useNetworkd = true;

      lanbat.profile = "test";
      lanbat.hostKey = hostKey;
      lanbat.hosts = hosts;
      lanbat.endpoints = endpoints;
      lanbat.deployment.overlay = {
        provider = "wireguard-mesh";
        subnet = "10.100.0.0/24";
        domain = "mesh.test";
      };
      # Placeholders at evaluation; test-secrets.nix encrypts the real test
      # key for this VM and points agenix at it.
      lanbat.deployment.secrets = {
        provider = "none";
        root = ../secrets;
      };
      lanbat.testSecrets."overlay-${hostKey}" = privateKey;

      environment.systemPackages = [
        pkgs.wireguard-tools
        pkgs.curl
      ];
    };
in
pkgs.testers.runNixOSTest {
  name = "overlay-mesh";

  nodes.a = node "a" snakeoil.peer0.privateKey {
    lanbat.services.demo.endpoint = demoEndpoint;
    systemd.services.demo = httpServer 8000;
    systemd.services.undeclared = httpServer 8001;
  };

  nodes.b = node "b" snakeoil.peer1.privateKey { };

  testScript = ''
    start_all()

    with subtest("the interface comes up with the decrypted key"):
        for m, ip in ((a, "10.100.0.1"), (b, "10.100.0.2")):
            m.wait_for_unit("systemd-networkd.service")
            m.wait_until_succeeds(f"ip -4 addr show dev lanbat0 | grep -q 'inet {ip}/24'")
            m.succeed("test \"$(stat -c '%U:%G %a' /run/agenix/overlay-${"$"}(hostname))\" = 'root:systemd-network 440'")
            m.succeed("test \"$(wg show lanbat0 peers | wc -l)\" = 1")
            m.succeed("systemctl start systemd-networkd-wait-online@lanbat0.service")

    with subtest("keepalive only toward the peer with an endpoint"):
        b.succeed("wg show lanbat0 persistent-keepalive | grep -q '\\s25$'")
        a.succeed("wg show lanbat0 persistent-keepalive | grep -q '\\soff$'")

    with subtest("each reaches the other across the overlay"):
        # b dials a, which has the endpoint; a can only answer once b has.
        b.wait_until_succeeds("ping -c1 -W2 10.100.0.1")
        a.wait_until_succeeds("ping -c1 -W2 10.100.0.2")

    with subtest("overlay names resolve to overlay addresses"):
        b.succeed("getent hosts a.mesh.test | grep -q '^10.100.0.1 '")
        a.succeed("getent hosts b.mesh.test | grep -q '^10.100.0.2 '")
        b.succeed("ping -c1 -W2 a.mesh.test")

    a.wait_for_open_port(8000)
    a.wait_for_open_port(8001)

    with subtest("a declared endpoint is reachable across the overlay"):
        b.succeed("curl -sf --max-time 5 http://a.mesh.test:8000/ | grep -q hello")

    with subtest("an undeclared port is refused across the overlay"):
        b.fail("curl -sf --max-time 5 http://a.mesh.test:8001/")

    with subtest("the overlay edge is not open over the LAN"):
        b.fail("curl -sf --max-time 5 http://192.168.1.1:8000/")
  '';
}

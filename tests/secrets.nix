# tests/secrets.nix
#
# The secrets wiring (modules/wiring/secrets.nix), evaluated without agenix:
# requirements resolve through the profile's provider, readers get a path from
# lanbat.secrets, and a requirement the profile cannot satisfy fails with a
# message that names the secret and what requires it. A requirement that is
# off is not provisioned and needs no file, and a secret shared with other
# services lists them as readers. Pure evaluation.
{ lib, pkgs }:

let
  eval =
    {
      provider ? "none",
      services ? { },
      hostSecrets ? { },
    }:
    (lib.nixosSystem {
      modules = [
        ../modules/core/settings.nix
        ../modules/core/services.nix
        ../modules/wiring/secrets.nix
        ./lib/age-option-stub.nix
        {
          boot.isContainer = true;
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "25.11";
          lanbat.profile = "test";
          lanbat.hostKey = "server";
          lanbat.deployment.secrets = {
            inherit provider;
            # The repository's own encrypted files: only their presence is read.
            root = ../secrets;
          };
          lanbat.services = services;
          lanbat.hostSecrets = hostSecrets;
        }
      ];
    }).config;

  failed = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);

  # A service needing one secret that exists in secrets/ and one that does not.
  demo = {
    demo.secrets = {
      grafana-env.mode = "0440";
      no-such-secret = { };
    };
  };

  # A requirement that is off, for a file the profile does not have either.
  optional = {
    optional.secrets = {
      grafana-env = { };
      feature-key = {
        enable = false;
        owner = "root";
      };
    };
  };
  off = eval {
    provider = "agenix";
    services = optional;
    hostSecrets.overlay-server.enable = false;
  };

  # A secret one service declares and others read.
  shared = eval {
    services = {
      broker.secrets.broker-pass = {
        group = "client";
        mode = "0440";
      };
      client.readsSecrets = [ "broker-pass" ];
      other.readsSecrets = [ "broker-pass" ];
    };
  };
  orphan = eval { services.client.readsSecrets = [ "broker-pass" ]; };
  readsOff = eval {
    services = {
      broker.secrets.broker-pass.enable = false;
      client.readsSecrets = [ "broker-pass" ];
    };
  };

  none = eval { services = demo; };
  agenix = eval {
    provider = "agenix";
    services = demo;
  };
  host = eval {
    hostSecrets.overlay-server = {
      owner = "root";
      group = "systemd-network";
      mode = "0440";
    };
  };

  expect = name: cond: if cond then null else "FAIL: ${name}";

  cases = [
    (expect "a reader gets the decrypted path" (
      none.lanbat.secrets.grafana-env.path == "/run/agenix/grafana-env"
    ))
    (expect "the owner defaults to the service" (none.lanbat.secrets.grafana-env.owner == "demo"))
    (expect "the requirement records who declared it" (
      none.lanbat.secrets.no-such-secret.declaredBy == "demo"
    ))
    (expect "none resolves to a placeholder, even for a file the profile lacks" (
      lib.hasInfix "lanbat-placeholder-no-such-secret" (toString none.age.secrets.no-such-secret.file)
    ))
    (expect "none fails no assertion" (failed none == [ ]))
    (expect "agenix reads the profile's encrypted file" (
      lib.hasSuffix "/secrets/grafana-env.age" (toString agenix.age.secrets.grafana-env.file)
    ))
    (expect "owner, group and mode reach the provider unchanged" (
      let
        s = agenix.age.secrets.grafana-env;
      in
      s.owner == "demo" && s.mode == "0440" && s.path == "/run/agenix/grafana-env"
    ))
    (expect "a missing provision names the secret, the service and the host" (
      failed agenix == [
        (
          "lanbat: secret \"no-such-secret\" is required by demo on server,"
          + " but the profile provides no no-such-secret.age in deployment.secrets.root."
          + " Create it (secrets/README.md), or remove what requires it."
        )
      ]
    ))
    (expect "a missing provision throws where its file is read" (
      !(builtins.tryEval (toString agenix.age.secrets.no-such-secret.file)).success
    ))
    (expect "a host secret is provisioned like a service secret" (
      host.age.secrets.overlay-server.group == "systemd-network"
      && host.lanbat.secrets.overlay-server.path == "/run/agenix/overlay-server"
    ))
    (expect "a requirement that is off is not provisioned" (
      !(off.lanbat.secrets ? feature-key) && !(off.age.secrets ? feature-key)
    ))
    (expect "a host secret that is off is not provisioned" (
      !(off.lanbat.secrets ? overlay-server) && !(off.age.secrets ? overlay-server)
    ))
    (expect "a requirement that is off needs no file" (failed off == [ ]))
    (expect "the requirements that are on are still provisioned" (
      lib.attrNames off.age.secrets == [ "grafana-env" ]
    ))
    (expect "a declaration that is off is still recorded" (
      off.lanbat.secretDeclarations.feature-key.enable == false
      && off.lanbat.secretDeclarations.feature-key.declaredBy == "optional"
    ))
    (expect "a shared secret is provisioned once, as its declarer says" (
      let
        s = shared.age.secrets.broker-pass;
      in
      s.owner == "broker" && s.group == "client" && s.mode == "0440"
    ))
    (expect "a shared secret lists its readers" (
      shared.lanbat.secrets.broker-pass.readers == [
        "client"
        "other"
      ]
      && shared.lanbat.secrets.broker-pass.declaredBy == "broker"
    ))
    (expect "reading a shared secret fails no assertion" (failed shared == [ ]))
    (expect "reading a secret nothing on the host declares names both sides" (
      failed orphan == [
        (
          "lanbat: client reads secret \"broker-pass\" on server, but no service on server"
          + " declares it. Place the service that declares it on this host, or make the"
          + " read conditional on that service."
        )
      ]
    ))
    (expect "reading a secret whose requirement is off names the declarer" (
      failed readsOff == [
        (
          "lanbat: client reads secret \"broker-pass\" on server, but its requirement in"
          + " broker is off (enable = false). Make the read as conditional as the requirement."
        )
      ]
    ))
  ];

  failures = lib.filter (x: x != null) cases;
in
pkgs.runCommand "secrets-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "secrets checks failed:" >&2
    ${lib.concatStringsSep "\n" (map (msg: "echo \"  - ${msg}\" >&2") failures)}
    exit 1
  fi
  touch $out
''

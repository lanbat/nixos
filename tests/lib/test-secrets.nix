# tests/lib/test-secrets.nix
#
# Test-only agenix secrets for VM tests. The real secrets/*.age files are
# encrypted to the real hosts, so a test VM can't decrypt them. This module
# generates a throwaway SSH host key while building, encrypts a dummy value for
# every secret the services declare, and points agenix at them.
#
# Caddy's root CA key is declared with age.secrets directly, and Caddy refuses
# a key that does not match the pinned root certificate. When the host runs
# Caddy, this module also generates a throwaway root certificate and key, and
# replaces the committed certificate with it.
#
# Never import it into a real host.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Every secret the services declare, and the host's overlay key, which no
  # service declares, when the host is on an overlay.
  overlayInterface = (config.lanbat.overlay or { }).interface or null;
  names = lib.unique (
    lib.concatMap (svc: lib.attrNames svc.secrets) (lib.attrValues config.lanbat.services)
    ++ lib.optional (overlayInterface != null) "overlay-${config.lanbat.hostKey}"
  );
  contents = config.lanbat.testSecrets;

  # services/caddy.nix pins the internal CA's root to the committed
  # certificate and its agenix-encrypted key.
  caddyCa = config.lanbat.services ? caddy;
  caddyCaKey = "caddy-ca-root-key";

  secrets =
    pkgs.runCommand "lanbat-test-secrets"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.openssh
          pkgs.openssl
        ];
      }
      ''
        mkdir $out
        ssh-keygen -q -t ed25519 -N "" -C lanbat-test -f $out/host_key
        ${lib.concatMapStrings (name: ''
          printf '%s' ${lib.escapeShellArg (contents.${name} or "test-value")} \
            | age -R $out/host_key.pub -o $out/${name}.age
        '') names}
        ${lib.optionalString caddyCa ''
          openssl ecparam -name prime256v1 -genkey -noout -out ca-root.key
          openssl req -x509 -new -key ca-root.key -sha256 -days 3650 \
            -subj "/CN=Lanbat Test Root CA" \
            -addext "basicConstraints=critical,CA:TRUE" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" \
            -out $out/caddy-ca-root.crt
          age -R $out/host_key.pub -o $out/${caddyCaKey}.age < ca-root.key
        ''}
      '';
in
{
  options.lanbat.testSecrets = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Plaintext of test secrets by name. Secrets not listed get \"test-value\".";
  };

  config = lib.mkMerge [
    {
      age.identityPaths = [ "${secrets}/host_key" ];
      age.secrets = lib.genAttrs names (name: {
        file = lib.mkForce "${secrets}/${name}.age";
      });
    }
    (lib.mkIf caddyCa {
      age.secrets.${caddyCaKey}.file = lib.mkForce "${secrets}/${caddyCaKey}.age";
      environment.etc."caddy/ca-root.crt".source = lib.mkForce "${secrets}/caddy-ca-root.crt";
    })
  ];
}

# tests/lib/test-secrets.nix
#
# Test-only agenix secrets for VM tests. The real secrets/*.age files are
# encrypted to the real hosts, so a test VM can't decrypt them. This module
# generates a throwaway SSH host key while building, encrypts a dummy value for
# every secret the services declare, and points agenix at them.
#
# Never import it into a real host.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  names = lib.unique (
    lib.concatMap (svc: lib.attrNames svc.secrets) (lib.attrValues config.lanbat.services)
  );
  contents = config.lanbat.testSecrets;

  secrets =
    pkgs.runCommand "lanbat-test-secrets"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.openssh
        ];
      }
      ''
        mkdir $out
        ssh-keygen -q -t ed25519 -N "" -C lanbat-test -f $out/host_key
        ${lib.concatMapStrings (name: ''
          printf '%s' ${lib.escapeShellArg (contents.${name} or "test-value")} \
            | age -R $out/host_key.pub -o $out/${name}.age
        '') names}
      '';
in
{
  options.lanbat.testSecrets = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Plaintext of test secrets by name. Secrets not listed get \"test-value\".";
  };

  config = {
    age.identityPaths = [ "${secrets}/host_key" ];
    age.secrets = lib.genAttrs names (name: {
      file = lib.mkForce "${secrets}/${name}.age";
    });
  };
}

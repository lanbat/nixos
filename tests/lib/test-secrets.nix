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
  # Every secret the host is provisioned with: the requirements of its services
  # and its host secrets (such as its overlay key) that are on.
  names = lib.attrNames config.lanbat.secrets;
  contents = config.lanbat.testSecrets;
  files = config.lanbat.testSecretFiles;

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
        ${lib.concatMapStrings (
          name:
          if files ? ${name} then
            ''
              age -R $out/host_key.pub -o $out/${name}.age < ${files.${name}}
            ''
          else
            ''
              printf '%s' ${lib.escapeShellArg (contents.${name} or "test-value")} \
                | age -R $out/host_key.pub -o $out/${name}.age
            ''
        ) names}
      '';
in
{
  options.lanbat.testSecrets = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Plaintext of test secrets by name. Secrets not listed get \"test-value\".";
  };

  options.lanbat.testSecretFiles = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = { };
    description = "Test secrets whose plaintext is a file built with the test, such as a key pair. Takes precedence over testSecrets.";
  };

  config = {
    age.identityPaths = [ "${secrets}/host_key" ];
    age.secrets = lib.genAttrs names (name: {
      file = lib.mkForce "${secrets}/${name}.age";
    });
  };
}

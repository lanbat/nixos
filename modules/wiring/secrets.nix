# modules/wiring/secrets.nix
#
# Secrets, from requirement to file.
#
# A service declares the secrets it needs in lanbat.services.<name>.secrets; a
# host-level module that no service owns (the overlay key) declares them in
# lanbat.hostSecrets. Those are requirements: they say who reads the file and
# with which owner and mode, never where it comes from.
#
# The profile's provider (deployment.secrets.provider) satisfies them, and the
# result is lanbat.secrets.<secret>: every reader takes the decrypted file's
# path from lanbat.secrets.<secret>.path, whichever provider is behind it.
#
# Providers:
#   agenix  decrypts <deployment.secrets.root>/<secret>.age at activation to
#           /run/agenix/<secret>.
#   none    resolves every requirement to a placeholder in the Nix store, still
#           through agenix, so evaluation and the checks need no encrypted
#           files. Never deployed.
#
# A provider only has to turn the requirements into files and report their
# paths: requirements and readers do not change when another one is added.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;

  inherit (config.lanbat.deployment.secrets) provider root;
  hostKey = config.lanbat.hostKey or "this host";

  requirementOptions = {
    owner = mkOption {
      type = types.str;
      description = "User that can read the decrypted secret.";
    };
    group = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Group of the decrypted secret (the provider's default when null).";
    };
    mode = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Mode of the decrypted secret (the provider's default, 0400, when null).";
    };
  };

  # Every requirement on this host, by secret name, with what declared it.
  requirements =
    lib.foldlAttrs (
      acc: svcName: svc:
      acc
      // lib.mapAttrs (_: req: {
        inherit (req) owner group mode;
        declaredBy = svcName;
      }) svc.secrets
    ) { } config.lanbat.services
    // lib.mapAttrs (name: req: {
      inherit (req) owner group mode;
      declaredBy = "host secret ${name}";
    }) config.lanbat.hostSecrets;

  # Where a secret's encrypted file comes from.
  #
  # Under "none" each secret resolves to a store file instead, so evaluation and
  # the flake checks need no encrypted files at all. That is what lets somebody
  # add a service with secrets and run nix flake check without holding any keys.
  #
  # Under "agenix" the file is <root>/<name>.age. One that is missing fails here,
  # naming the secret and what requires it, rather than as a bare missing path
  # somewhere inside the activation script.
  sourceOf = name: root + "/${name}.age";
  unprovided = name: provider != "none" && !builtins.pathExists (sourceOf name);
  missingMessage =
    name: req:
    "lanbat: secret \"${name}\" is required by ${req.declaredBy} on ${hostKey},"
    + " but the profile provides no ${name}.age in deployment.secrets.root."
    + " Create it (secrets/README.md), or remove what requires it.";

  fileFor =
    name: req:
    if provider == "none" then
      pkgs.writeText "lanbat-placeholder-${name}" ''
        This is not a secret. The profile sets deployment.secrets.provider to
        "none", which resolves every secret to this placeholder so the
        configuration can be evaluated without any encrypted files.

        A host built this way must not be deployed: ${name} would be this text.
      ''
    else if unprovided name then
      throw (missingMessage name req)
    else
      sourceOf name;

  provisioned = lib.mapAttrs (name: req: req // { file = fileFor name req; }) requirements;
in
{
  options.lanbat.hostSecrets = mkOption {
    type = types.attrsOf (types.submodule { options = requirementOptions; });
    default = { };
    example = lib.literalExpression ''
      {
        overlay-server = {
          owner = "root";
          group = "systemd-network";
          mode = "0440";
        };
      }
    '';
    description = ''
      Secrets this host needs that belong to no service, such as its overlay
      key. Service secrets are declared in lanbat.services.<name>.secrets.
    '';
  };

  options.lanbat.secrets = mkOption {
    type = types.attrsOf (
      types.submodule {
        options = requirementOptions // {
          path = mkOption {
            type = types.str;
            description = "Path of the decrypted file on this host. Readers take the path from here.";
          };
          file = mkOption {
            type = types.either types.path types.str;
            description = "Source the provider decrypts the secret from.";
          };
          declaredBy = mkOption {
            type = types.str;
            description = "Service (or host secret) that declares the requirement.";
          };
        };
      }
    );
    readOnly = true;
    description = ''
      The secrets this host is provisioned with, by name: each requirement from
      lanbat.services.<name>.secrets and lanbat.hostSecrets, satisfied by the
      profile's provider.

      Read a secret's decrypted file as lanbat.secrets.<name>.path, never
      through the provider's own options, so that the reader does not change
      when the provider does.
    '';
  };

  config.lanbat.secrets = lib.mapAttrs (
    name: s: s // { inherit (config.age.secrets.${name}) path; }
  ) provisioned;

  config.assertions =
    lib.mapAttrsToList (name: req: {
      assertion = !unprovided name;
      message = missingMessage name req;
    }) requirements
    ++ [
      {
        assertion = provider != "sops";
        message =
          "lanbat.deployment.secrets.provider is \"sops\", which is named in the"
          + " option but not implemented yet. Use \"agenix\", or \"none\" to"
          + " evaluate without encrypted files.";
      }
    ];

  # Loud rather than silent: a host built this way looks complete and is not.
  config.warnings = lib.optional (provider == "none") (
    "lanbat.deployment.secrets.provider is \"none\", so every secret resolves"
    + " to a placeholder in the Nix store. This profile evaluates and builds but"
    + " must not be deployed."
  );

  # The agenix provider, which "none" also runs through.
  config.age.secrets = lib.mapAttrs (
    _: s:
    {
      inherit (s) file owner;
    }
    // lib.optionalAttrs (s.group != null) { inherit (s) group; }
    // lib.optionalAttrs (s.mode != null) { inherit (s) mode; }
  ) provisioned;
}

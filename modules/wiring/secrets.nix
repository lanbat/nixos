# modules/wiring/secrets.nix
#
# Declares an agenix secret for every entry in
# lanbat.services.<name>.secrets. The encrypted file is secrets/<secret>.age,
# decrypted at boot to /run/agenix/<secret>; services read it through
# config.age.secrets.<secret>.path.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;

  provider = config.lanbat.deployment.secrets.provider;

  # Where a secret's encrypted file comes from.
  #
  # The path used to be built from this repository's own secrets directory,
  # which meant a deployment consuming lanbat as a flake input pointed at the
  # maintainer's encrypted files and could not substitute its own. It now comes
  # from the profile.
  #
  # Under "none" each secret resolves to a store file instead, so evaluation and
  # the flake checks need no encrypted files at all. That is what lets somebody
  # add a service with secrets and run nix flake check without holding any keys.
  fileFor =
    name:
    if provider == "none" then
      pkgs.writeText "lanbat-placeholder-${name}" ''
        This is not a secret. The profile sets deployment.secrets.provider to
        "none", which resolves every secret to this placeholder so the
        configuration can be evaluated without any encrypted files.

        A host built this way must not be deployed: ${name} would be this text.
      ''
    else
      config.lanbat.deployment.secrets.root + "/${name}.age";
  secrets = lib.concatMap lib.attrsToList (
    lib.mapAttrsToList (_: svc: svc.secrets) config.lanbat.services
  );
in
{
  options.lanbat.secretPath = mkOption {
    type = types.functionTo types.str;
    internal = true;
    readOnly = true;
    description = ''
      Path of a decrypted secret, by name.

      A service module reads this when it needs a secret that another service
      declares, so that a deployment leaving that other service out gets told
      what is missing rather than an attribute error from inside a unit.

      Reach for it only where the borrowing service genuinely cannot run
      without the other one. Where the integration is optional, make the block
      that uses the secret conditional on lanbat.hasService instead, so the
      service still works on its own.
    '';
  };

  options.lanbat.secretFile = mkOption {
    type = types.functionTo (types.either types.path types.str);
    internal = true;
    readOnly = true;
    description = ''
      Encrypted source file of a secret, by name, resolved through the profile's
      secrets provider.

      For the few secrets that are declared with age.secrets directly because
      no single service owns them, such as a host's overlay key, so that they
      follow deployment.secrets like every other secret instead of pointing
      into this repository.
    '';
  };

  config.lanbat.secretFile = fileFor;

  config.lanbat.secretPath =
    name:
    (config.age.secrets.${name} or (throw (
      "lanbat: secret \"${name}\" is not available on this host."
      + " It is declared by a service that is not part of this deployment;"
      + " add that service to this host, or drop the one that needs it."
    ))
    ).path;

  config.assertions = [
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

  config.age.secrets = lib.listToAttrs (
    map (
      s:
      lib.nameValuePair s.name (
        {
          file = fileFor s.name;
          inherit (s.value) owner;
        }
        // lib.optionalAttrs (s.value.group != null) { inherit (s.value) group; }
        // lib.optionalAttrs (s.value.mode != null) { inherit (s.value) mode; }
      )
    ) secrets
  );
}

# modules/wiring/secrets.nix
#
# Declares an agenix secret for every entry in
# lanbat.services.<name>.secrets. The encrypted file is secrets/<secret>.age,
# decrypted at boot to /run/agenix/<secret>; services read it through
# config.age.secrets.<secret>.path.
{ config, lib, ... }:

let
  inherit (lib) mkOption types;
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

  config.lanbat.secretPath =
    name:
    (config.age.secrets.${name} or (throw (
      "lanbat: secret \"${name}\" is not available on this host."
      + " It is declared by a service that is not part of this deployment;"
      + " add that service to this host, or drop the one that needs it."
    ))
    ).path;

  config.age.secrets = lib.listToAttrs (
    map (
      s:
      lib.nameValuePair s.name (
        {
          file = ../../secrets + "/${s.name}.age";
          inherit (s.value) owner;
        }
        // lib.optionalAttrs (s.value.group != null) { inherit (s.value) group; }
        // lib.optionalAttrs (s.value.mode != null) { inherit (s.value) mode; }
      )
    ) secrets
  );
}

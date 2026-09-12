# modules/wiring/secrets.nix
#
# Declares an agenix secret for every entry in
# lanbat.services.<name>.secrets. The encrypted file is secrets/<secret>.age,
# decrypted at boot to /run/agenix/<secret>; services read it through
# config.age.secrets.<secret>.path.
{ config, lib, ... }:

let
  secrets = lib.concatMap lib.attrsToList (
    lib.mapAttrsToList (_: svc: svc.secrets) config.lanbat.services
  );
in
{
  age.secrets = lib.listToAttrs (
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

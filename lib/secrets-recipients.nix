# lib/secrets-recipients.nix
#
# Which hosts need each secret, derived from the hosts themselves rather than
# kept by hand: a host needs a secret when one of its services, or the host
# itself, requires it (lanbat.secrets), and a service that reads a secret
# another one declares (readsSecrets) must share its host, so placement is the
# whole answer. A requirement that is off needs no recipient.
#
# nix run .#secrets-recipients prints the result for a profile as the body of
# an agenix secrets.nix.
{
  lib,
  configurations,
  defaultProfile,
}:

let
  forProfile =
    optionalProfile:
    let
      profile = if optionalProfile == null then defaultProfile else optionalProfile;

      # This profile's hosts, by their key in deploy.nix.
      hosts = lib.mapAttrs' (_: host: lib.nameValuePair host.config.lanbat.hostKey host.config) (
        lib.filterAttrs (_: host: host.config.lanbat.profile == profile) configurations
      );

      holders =
        pick:
        lib.zipAttrsWith (_: hostKeys: lib.sort lib.lessThan hostKeys) (
          lib.mapAttrsToList (hostKey: cfg: lib.mapAttrs (_: _: hostKey) (pick cfg)) hosts
        );

      recipients = holders (cfg: cfg.lanbat.secrets);

      # Declared somewhere but required nowhere: no file is needed at all.
      off = removeAttrs (holders (cfg: lib.filterAttrs (_: d: !d.enable) cfg.lanbat.secretDeclarations)) (
        lib.attrNames recipients
      );

      line =
        name: hostKeys: "  \"${name}.age\".publicKeys = [ admin ${lib.concatStringsSep " " hostKeys} ];";

      text = lib.concatStringsSep "\n" (
        [
          "# agenix recipients for profile \"${profile}\", derived by nix run .#secrets-recipients"
          "# from each host's secret requirements. admin is your own key; every other"
          "# name is a host key from deploy.nix. Define them in a let block above this."
          "{"
        ]
        ++ lib.mapAttrsToList line recipients
        ++ [ "}" ]
        ++ lib.optionals (off != { }) (
          [ "# Declared, but off on every host of this profile, so no file is needed:" ]
          ++ lib.mapAttrsToList (
            name: hostKeys: "#   ${name}.age (${lib.concatStringsSep ", " hostKeys})"
          ) off
        )
      );
    in
    {
      inherit
        profile
        recipients
        off
        text
        ;
    };
in
forProfile

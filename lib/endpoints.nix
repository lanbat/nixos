# lib/endpoints.nix
#
# Builds the profile-wide service table from the first, descriptions-only pass.
#
# Kept apart from lib/default.nix so that the flake and the test fixtures build
# the table the same way. A fixture that skipped it would evaluate hosts with an
# empty table and hit errors no real deployment could produce.
{ lib }:

let
  mkTable =
    {
      profileName,
      # host name -> that host's lanbat.services, from the descriptions pass
      described,
      # the deploy manifest's hosts, for addresses
      hosts,
    }:
    let
      placedOn =
        svcName: lib.filter (hostName: described.${hostName} ? ${svcName}) (lib.attrNames described);

      allServiceNames = lib.unique (lib.concatMap lib.attrNames (lib.attrValues described));
    in
    lib.listToAttrs (
      map (
        svcName:
        let
          hostNames = placedOn svcName;
          # endpoint and account come from the service module, so every
          # placement agrees on them; take the first and check the rest.
          first = described.${lib.head hostNames}.${svcName};
          disagreeing = lib.filter (
            hostName:
            described.${hostName}.${svcName}.endpoint != first.endpoint
            || described.${hostName}.${svcName}.account != first.account
          ) hostNames;
        in
        lib.nameValuePair svcName (
          if disagreeing != [ ] then
            builtins.throw (
              "lanbat profile '${profileName}': service '${svcName}' describes a"
              + " different endpoint or account on ${lib.concatStringsSep ", " disagreeing}"
              + " than on ${lib.head hostNames}. A service must look the same"
              + " wherever it runs, or consumers cannot resolve it."
            )
          else
            {
              hosts = hostNames;
              addresses = lib.listToAttrs (
                map (hostName: lib.nameValuePair hostName hosts.${hostName}.networking.ip) hostNames
              );
              hostnames = lib.listToAttrs (
                map (hostName: lib.nameValuePair hostName hosts.${hostName}.networking.hostname) hostNames
              );
              inherit (first) endpoint account;
            }
        )
      ) allServiceNames
    );
in
{
  inherit mkTable;
}

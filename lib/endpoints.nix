# lib/endpoints.nix
#
# Builds the profile-wide service table from the first, descriptions-only pass.
#
# Kept apart from lib/default.nix so that the flake and the test fixtures build
# the table the same way. A fixture that skipped it would evaluate hosts with an
# empty table and hit errors no real deployment could produce.
{ lib }:

let
  # The part of a service's nfs description another host needs. The units stay
  # behind: they only mean something on the host that runs them.
  nfsOf = svc: {
    inherit (svc.nfs) drives storageHost;
  };

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
          # endpoint, account and the Pi storage it uses come from the service
          # module, so every placement agrees on them; take the first and check
          # the rest.
          first = described.${lib.head hostNames}.${svcName};
          disagreeing = lib.filter (
            hostName:
            described.${hostName}.${svcName}.endpoint != first.endpoint
            || described.${hostName}.${svcName}.account != first.account
            || nfsOf described.${hostName}.${svcName} != nfsOf first
          ) hostNames;
        in
        lib.nameValuePair svcName (
          if disagreeing != [ ] then
            builtins.throw (
              "lanbat profile '${profileName}': service '${svcName}' describes a"
              + " different endpoint, account or Pi storage on ${lib.concatStringsSep ", " disagreeing}"
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
              inherit (first) endpoint account consumes;
              # The storage Pi exports its drives to the hosts of the services
              # that use them, which it can only learn from here.
              nfs = nfsOf first;
            }
        )
      ) allServiceNames
    );
  # The one host running `name`, for a consumer that dials a single place.
  # Throws, naming the consumer, when the service runs nowhere in the profile or
  # on more than one host, since picking one of several would be a guess.
  soleHost =
    {
      endpoints,
      name,
      consumer,
    }:
    let
      hostNames = (endpoints.${name} or { hosts = [ ]; }).hosts;
    in
    if lib.length hostNames == 1 then
      lib.head hostNames
    else if hostNames == [ ] then
      builtins.throw "lanbat: ${consumer} consumes ${name}, which no host in this profile runs"
    else
      builtins.throw (
        "lanbat: ${consumer} consumes ${name}, which runs on more than one host"
        + " (${lib.concatStringsSep ", " hostNames}), and it can only connect to one"
      );

  # The hosts that mount drives from `storageHost` over NFS: every host running
  # a service whose nfs.drives is non-empty and whose storage host resolves to
  # it. A service that names no storage host uses the profile's primary one.
  nfsClientsOf =
    {
      endpoints,
      storageHost,
      primaryStorage,
    }:
    lib.sort (a: b: a < b) (
      lib.unique (
        lib.concatLists (
          lib.mapAttrsToList (
            _: entry:
            let
              nfs = entry.nfs or { drives = [ ]; };
              target = if (nfs.storageHost or null) == null then primaryStorage else nfs.storageHost;
            in
            if nfs.drives != [ ] && target == storageHost then
              lib.filter (h: h != storageHost) entry.hosts
            else
              [ ]
          ) endpoints
        )
      )
    );
in
{
  inherit mkTable soleHost nfsClientsOf;
}

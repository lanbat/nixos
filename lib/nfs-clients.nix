# lib/nfs-clients.nix
#
# The hosts a storage host serves over NFS, for modules/pi/nfs-exports.nix and
# the firewall in lib/roles/storage-pi.nix, which must agree on them.
#
# They are the hosts running a service whose nfs.drives is non-empty and whose
# storage host is this one, read from the profile-wide endpoint table. The
# addresses come from the overlay contract, which without an overlay is the
# LAN address in lanbat.hosts. Exports and firewall rules need an address, so a
# provider that cannot give one during evaluation is an error here.
{ config, lib }:

let
  endpointLib = import ./endpoints.nix { inherit lib; };
  thisHost = config.lanbat.hostKey;

  hosts = endpointLib.nfsClientsOf {
    endpoints = config.lanbat.endpoints;
    storageHost = thisHost;
    inherit (config.lanbat.deployment) primaryStorage;
  };

  addressOf =
    host:
    let
      address = config.lanbat.overlay.addressOf host;
    in
    if address == null then
      builtins.throw (
        "lanbat: ${thisHost} exports NFS to ${host}, but the overlay provider"
        + " '${config.lanbat.overlay.provider}' has no address for it during evaluation"
      )
    else
      address;
in
{
  inherit hosts;
  addresses = map addressOf hosts;
}

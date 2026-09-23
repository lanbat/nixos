# lib/nfs-clients.nix
#
# The hosts a storage host serves over NFS, for modules/pi/nfs-exports.nix and
# the firewall in lib/roles/storage-pi.nix, which must agree on them.
#
# They are the hosts running a service whose nfs.drives is non-empty and whose
# storage host is this one, read from the profile-wide endpoint table. The
# addresses are always the LAN addresses in lanbat.hosts, whatever overlay the
# profile runs: NFS stays on the LAN by design, since the server mounts it by
# the storage host's LAN address and Pi storage must not depend on the overlay
# being up (docs/failure-modes.md).
{ config, lib }:

let
  endpointLib = import ./endpoints.nix { inherit lib; };
  thisHost = config.lanbat.hostKey;

  hosts = endpointLib.nfsClientsOf {
    endpoints = config.lanbat.endpoints;
    storageHost = thisHost;
    inherit (config.lanbat.deployment) primaryStorage;
  };

  addressOf = host: config.lanbat.hosts.${host}.networking.ip;
in
{
  inherit hosts;
  addresses = map addressOf hosts;
}

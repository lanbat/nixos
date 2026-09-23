# modules/pi/nfs-exports.nix
#
# NFS server configuration — exports Pi storage to the hosts that use it.
#
# Export model
# ------------
# /mnt/storage-<drive>  →  every host running a service that uses this storage
# host (read/write, no_root_squash for service accounts), for every key of
# hosts.<key>.storage.drives
#
# "no_root_squash" is used because the clients' service accounts must write to
# the NFS paths without being squashed to nobody. Ownership is stored as the
# numeric UID of each service's lanbat.services.<name>.account. The Pi does not
# run those services, so modules/pi/storage.nix reads the same accounts from
# the profile-wide lanbat.endpoints table to own the directories it creates.
#
# Exports are restricted to those hosts' addresses, and the Pi firewall
# (lib/roles/storage-pi.nix) drops NFS from any other source.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  drives = config.lanbat.hosts.${config.lanbat.hostKey}.storage.drives;

  # The hosts running a service that declares nfs.drives on this storage host,
  # read from the profile-wide table: the storage Pi serves whoever uses it
  # rather than assuming the server. lib/roles/storage-pi.nix restricts the
  # NFS port to the same hosts.
  clients = import ../../lib/nfs-clients.nix { inherit config lib; };

  # Common NFS export options. mp exports a drive only while it is mounted, so
  # a locked drive is never served as the empty directory on the SD card.
  exportOpts = "rw,sync,no_subtree_check,no_root_squash,mp";
in
{
  services.nfs.server = {
    enable = true;
    # NFSv4 only — no portmap required.
    nproc = 8;

    # One line per drive, each exported to every client. With no client there
    # is no line at all: an export without a client list is open to anyone.
    exports = lib.optionalString (clients.addresses != [ ]) (
      lib.concatMapStrings (
        drive:
        "/mnt/storage-${drive}  "
        + lib.concatMapStringsSep " " (address: "${address}(${exportOpts})") clients.addresses
        + "\n"
      ) (lib.attrNames drives)
    );
  };

  # The NFS server starts at boot without waiting for the drives: each drive is
  # exported (mp) once its unlock service has mounted it, and storage-*-init
  # refreshes the exports then. One locked drive doesn't keep the other off
  # the network.

  # NFSv4 only. rpcbind is needed for NFSv3 clients; not required for v4-only.
  # mkForce to override the default-true set by the nfs module. With NFSv3
  # still enabled, rpc.nfsd tries to register with the missing rpcbind and
  # fails to start ("error starting threads: errno 111").
  services.rpcbind.enable = lib.mkForce false;
  services.nfs.settings.nfsd = {
    vers3 = false;
    udp = false;
  };

  # NFSv4 ID mapping domain — must match server config.
  services.nfs.idmapd.settings = {
    General = {
      Domain = config.lanbat.deployment.nfsIdmapdDomain;
    };
  };
}

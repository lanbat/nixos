# modules/pi/nfs-exports.nix
#
# NFS server configuration — exports Pi storage to the server.
#
# Export model
# ------------
# /mnt/storage-a  →  server (read/write, no_root_squash for service accounts)
# /mnt/storage-b  →  server (read/write, no_root_squash)
#
# "no_root_squash" is used because the server's service accounts (jellyfin,
# immich, frigate, qbt — UIDs 991-994) must write to the NFS paths without
# being squashed to nobody.  Ownership is stored as the numeric IDs pinned in
# each service's lanbat.services.<name>.account on the server.
#
# Security note: restrict exports to the server's IP only.
# The Pi firewall (hosts/pi/default.nix) also drops NFS from other sources.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  serverIp = config.lanbat.serverIp;

  # Common NFS export options. mp exports a drive only while it is mounted, so
  # a locked drive is never served as the empty directory on the SD card.
  exportOpts = "rw,sync,no_subtree_check,no_root_squash,mp";
in
{
  services.nfs.server = {
    enable = true;
    # NFSv4 only — no portmap required.
    nproc = 8;

    exports = ''
      /mnt/storage-a  ${serverIp}(${exportOpts})
      /mnt/storage-b  ${serverIp}(${exportOpts})
    '';
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
      Domain = config.lanbat.nfsIdmapdDomain; # same on both machines
    };
  };
}

# hosts/pi/services/nfs-exports.nix
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
# being squashed to nobody.  The UIDs/GIDs are consistent across both
# machines (see modules/common/users.nix), so this is safe.
#
# Security note: restrict exports to the server's IP only.
# The Pi firewall (hosts/pi/default.nix) also drops NFS from other sources.
{ config, pkgs, lib, ... }:

let
  serverIp = config.lanbat.serverIp;

  # Common NFS export options.
  exportOpts = "rw,sync,no_subtree_check,no_root_squash";
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

  # The NFS server must wait for the storage drives to be mounted and
  # initialized.  Otherwise it exports empty paths.
  systemd.services."nfs-server" = {
    after    = [ "mnt-storage-a.mount" "mnt-storage-b.mount"
                 "storage-a-init.service" "storage-b-init.service" ];
    requires = [ "mnt-storage-a.mount" "mnt-storage-b.mount" ];
  };

  # rpcbind is needed for NFSv3 clients; not required for v4-only.
  # mkForce to override the default-true set by the nfs module.
  services.rpcbind.enable = lib.mkForce false;

  # NFSv4 ID mapping domain — must match server config.
  services.nfs.idmapd.settings = {
    General = {
      Domain = config.lanbat.nfsIdmapdDomain; # same on both machines
    };
  };
}

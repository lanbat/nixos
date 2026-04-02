# modules/server/nfs-mounts.nix
#
# NFS mount units for the two Pi storage volumes.
#
# Design intent
# -------------
#  - The Pi exports /mnt/storage-a and /mnt/storage-b over NFSv4.
#  - The server mounts them at /srv/storage/a and /srv/storage/b.
#  - Services that need Pi storage declare a dependency on these mount units
#    (see modules/server/nfs-dependent-service.nix).
#  - When the Pi is unreachable or reboots, the mount stalls; systemd detects
#    this and stops dependent services (bindsTo + after).
#  - When the NFS mount comes back, systemd restarts the mount unit and then
#    restarts dependent services automatically (restartIfChanged + restart=on-failure
#    in the service units).
#
# IMPORTANT: "hard" NFS mounts block indefinitely on network loss.
# We use "soft,timeo=30,retrans=3" so the kernel returns errors after ~90 s
# rather than hanging forever.  Services should handle EIO gracefully, but
# in our model they are stopped before that point via the systemd dependency.
#
# Assumptions:
#  - Pi hostname "pi5" resolves on the LAN (via router/DNS).
#    Alternatively, set it to the Pi's static IPv4 address.
#  - NFSv4 is used; no portmap/rpcbind required for v4-only.
{ config, lib, ... }:

let
  piHost = config.lanbat.piHostname;

  # Common NFS mount options.
  # "x-systemd.automount" means the mount is created lazily on first access.
  # "noauto" prevents systemd from mounting at boot before it is needed.
  # "x-systemd.idle-timeout=600" unmounts after 10 min of inactivity.
  nfsOpts = [
    "nfsvers=4.2"
    "soft"
    "timeo=30"
    "retrans=3"
    "rsize=131072"
    "wsize=131072"
    "async"
    "noatime"
    "x-systemd.automount"
    "noauto"
    "x-systemd.idle-timeout=600"
    "x-systemd.mount-timeout=30"
    "_netdev"
  ];
in
{
  # Ensure the local mount points exist.
  systemd.tmpfiles.rules = [
    "d /srv/storage      0755 root root -"
    "d /srv/storage/a    0755 root root -"
    "d /srv/storage/b    0755 root root -"
  ];

  fileSystems."/srv/storage/a" = {
    device  = "${piHost}:/mnt/storage-a";
    fsType  = "nfs4";
    options = nfsOpts;
  };

  fileSystems."/srv/storage/b" = {
    device  = "${piHost}:/mnt/storage-b";
    fsType  = "nfs4";
    options = nfsOpts;
  };

  # NFSv4 ID mapping domain — must match Pi config.
  services.nfs.idmapd.settings = {
    General = {
      Domain = config.lanbat.nfsIdmapdDomain;
    };
  };

  # Keep rpcbind out — NFSv4 doesn't need it.
  services.rpcbind.enable = false;

  # Make sure the network is up before attempting mounts.
  # The automount units already carry _netdev, but belt-and-suspenders:
  systemd.services."srv-storage-a.automount" = {
    after    = [ "network-online.target" ];
    requires = [ "network-online.target" ];
  };
  systemd.services."srv-storage-b.automount" = {
    after    = [ "network-online.target" ];
    requires = [ "network-online.target" ];
  };
}

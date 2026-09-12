# modules/wiring/nfs.nix
#
# Pi storage over NFS, and the dependencies of the services that use it.
#
# The Pi exports /mnt/storage-a and /mnt/storage-b over NFSv4; the server
# mounts them at /srv/storage/a and /srv/storage/b. Every unit listed in
# lanbat.services.<name>.nfs.units gets After= and BindsTo= on the mount of
# each drive in nfs.drives, so systemd stops it when the Pi goes away, plus
# Restart=on-failure so it comes back.
#
# The mounts are "soft,timeo=30,retrans=3": the kernel returns errors after
# about 90 s instead of hanging forever when the Pi is unreachable.
{ config, lib, ... }:

let
  piHost = config.lanbat.piHostname;

  mountUnit = drive: "srv-storage-${drive}.mount";

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

  dependents = lib.filterAttrs (_: svc: svc.nfs.drives != [ ]) config.lanbat.services;

  unitDeps = lib.concatLists (
    lib.mapAttrsToList (
      _: svc:
      map (unit: {
        inherit unit;
        inherit (svc.nfs) drives;
      }) svc.nfs.units
    ) dependents
  );
in
{
  # NFS mounts use piHostname; ensure it resolves even without LAN DNS/mDNS.
  networking.hosts.${config.lanbat.piIp} = [ config.lanbat.piHostname ];

  systemd.tmpfiles.rules = [
    "d /srv/storage      0755 root root -"
    "d /srv/storage/a    0755 root root -"
    "d /srv/storage/b    0755 root root -"
  ];

  fileSystems."/srv/storage/a" = {
    device = "${piHost}:/mnt/storage-a";
    fsType = "nfs4";
    options = nfsOpts;
  };

  fileSystems."/srv/storage/b" = {
    device = "${piHost}:/mnt/storage-b";
    fsType = "nfs4";
    options = nfsOpts;
  };

  # NFSv4 ID mapping domain; must match the Pi.
  services.nfs.idmapd.settings.General.Domain = config.lanbat.nfsIdmapdDomain;

  # NFSv4 doesn't need rpcbind.
  services.rpcbind.enable = lib.mkForce false;

  systemd.services = lib.mkMerge (
    map (dep: {
      ${dep.unit} = {
        after = map mountUnit dep.drives;
        bindsTo = map mountUnit dep.drives;
        serviceConfig.Restart = lib.mkDefault "on-failure";
        serviceConfig.RestartSec = lib.mkDefault "10s";
      };
    }) unitDeps
  );
}

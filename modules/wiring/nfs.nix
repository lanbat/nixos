# modules/wiring/nfs.nix
#
# Pi storage over NFS, and the dependencies of the services that use it.
{ config, lib, ... }:

let
  hosts = config.lanbat.hosts;
  defaultStorageHost = config.lanbat.deployment.primaryStorage;

  storageHostFor = svc: svc.nfs.storageHost or defaultStorageHost;

  storageHostname = host: hosts.${host}.networking.hostname;
  storageIp = host: hosts.${host}.networking.ip;

  mountUnit = drive: "srv-storage-${drive}.mount";
  mountPoint = drive: "/srv/storage/${drive}";

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

  storageHosts = lib.unique (
    lib.filter (h: h != null) (map storageHostFor (lib.attrValues dependents))
  );

  hostResolutions = lib.concatLists (
    map (
      host:
      let
        ip = storageIp host;
        hostname = storageHostname host;
      in
      [
        {
          "${ip}" = [ hostname ];
        }
      ]
    ) storageHosts
  );
in
{
  networking.hosts = lib.mkMerge hostResolutions;

  systemd.tmpfiles.rules = [
    "d /srv/storage      0755 root root -"
    "d /srv/storage/a    0755 root root -"
    "d /srv/storage/b    0755 root root -"
  ];

  fileSystems = lib.mkMerge (
    lib.flatten (
      map (
        host:
        let
          hostname = storageHostname host;
        in
        [
          {
            "/srv/storage/a" = {
              device = "${hostname}:/mnt/storage-a";
              fsType = "nfs4";
              options = nfsOpts;
            };
          }
          {
            "/srv/storage/b" = {
              device = "${hostname}:/mnt/storage-b";
              fsType = "nfs4";
              options = nfsOpts;
            };
          }
        ]
      ) storageHosts
    )
  );

  services.nfs.idmapd.settings.General.Domain = config.lanbat.deployment.nfsIdmapdDomain;

  services.rpcbind.enable = lib.mkForce false;

  systemd.services = lib.mkMerge (
    map (dep: {
      ${dep.unit} = {
        after = map mountUnit dep.drives;
        bindsTo = map mountUnit dep.drives;
        unitConfig.ConditionPathIsMountPoint = map mountPoint dep.drives;
        serviceConfig.Restart = lib.mkDefault "on-failure";
        serviceConfig.RestartSec = lib.mkDefault "10s";
      };
    }) unitDeps
  );
}

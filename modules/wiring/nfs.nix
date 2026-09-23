# modules/wiring/nfs.nix
#
# Pi storage over NFS, and the dependencies of the services that use it.
{ config, lib, ... }:

let
  hosts = config.lanbat.hosts;
  defaultStorageHost = config.lanbat.deployment.primaryStorage;

  # `or` does not fall through on `null` (null or x == null), so use an
  # explicit null check for the per-service override.
  storageHostFor =
    svc: if svc.nfs.storageHost == null then defaultStorageHost else svc.nfs.storageHost;

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

  # Every drive of every storage host in use, by name. A client mounts all of a
  # storage host's drives rather than only the ones its services name, because
  # host-level jobs such as the backups write to a drive without being a service
  # that could declare it.
  drivesOf = host: lib.attrNames hosts.${host}.storage.drives;
  usedDrives = lib.unique (lib.concatMap drivesOf storageHosts);

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
  ]
  ++ map (drive: "d ${mountPoint drive}    0755 root root -") usedDrives;

  fileSystems = lib.mkMerge (
    lib.flatten (
      map (
        host:
        let
          hostname = storageHostname host;
        in
        map (drive: {
          ${mountPoint drive} = {
            device = "${hostname}:/mnt/storage-${drive}";
            fsType = "nfs4";
            options = nfsOpts;
          };
        }) (drivesOf host)
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

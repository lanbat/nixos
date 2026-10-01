# tests/qbittorrent-userns.nix
#
# The linuxserver image switches to PUID/PGID inside the container. Rootless
# Podman maps container IDs into qbt's sub-ID range, so without an explicit map
# PUID lands on an unprivileged sub-UID and cannot write the qbt:media media
# folders. The container's maps must send PUID and PGID to namespace ID 0 (the
# host qbt account) and cover every other ID exactly once. Pure evaluation of
# the container definition.
{ lib, pkgs }:

let
  config =
    (lib.nixosSystem {
      modules = [
        ../modules/core/settings.nix
        ../modules/core/services.nix
        ../modules/wiring/accounts.nix
        ../services/qbittorrent.nix
        (
          { lib, ... }:
          {
            boot.isContainer = true;
            nixpkgs.hostPlatform = "x86_64-linux";
            system.stateVersion = "25.11";
            users.groups.media.gid = 988;
            lanbat.deployment = {
              timezone = "UTC";
              serverIp = "192.0.2.10";
            };
          }
        )
      ];
    }).config;

  container = config.virtualisation.oci-containers.containers.qbittorrent;
  puid = lib.toInt container.environment.PUID;
  pgid = lib.toInt container.environment.PGID;

  # [ { inside; outside; count; } ] from "--uidmap=<inside>:<outside>:<count>".
  maps =
    flag:
    map (
      o:
      let
        parts = map lib.toInt (lib.splitString ":" (lib.removePrefix "${flag}=" o));
      in
      {
        inside = lib.elemAt parts 0;
        outside = lib.elemAt parts 1;
        count = lib.elemAt parts 2;
      }
    ) (lib.filter (lib.hasPrefix "${flag}=") container.extraOptions);

  mapsTo =
    flag: id:
    lib.any (m: m.inside <= id && id < m.inside + m.count && m.outside + id - m.inside == 0) (
      maps flag
    );

  # Every container ID 0..65535 is mapped exactly once, and no namespace ID twice.
  complete =
    flag:
    let
      ms = maps flag;
      total = lib.foldl' (n: m: n + m.count) 0 ms;
      sortedBy = f: lib.sort (a: b: f a < f b) ms;
      contiguous =
        f:
        (lib.foldl' (acc: m: if acc == null || f m != acc then null else acc + m.count) 0 (sortedBy f))
        != null;
    in
    ms != [ ] && total == 65536 && contiguous (m: m.inside) && contiguous (m: m.outside);

  checks = {
    "PUID maps to the host qbt account" = mapsTo "--uidmap" puid;
    "PGID maps to qbt's own group" = mapsTo "--gidmap" pgid;
    "the UID map covers every ID once" = complete "--uidmap";
    "the GID map covers every ID once" = complete "--gidmap";
    # State written under the old mapping belongs to a sub-ID; handing it to
    # qbt before each start keeps the session readable to PUID.
    "state is handed to qbt before every start" = lib.any (
      cmd: lib.hasInfix "chown -R qbt:qbt /var/lib/qbittorrent" (cmd.text or (builtins.toString cmd))
    ) (lib.toList config.systemd.services.podman-qbittorrent.serviceConfig.ExecStartPre);
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
if failed != [ ] then
  throw "qbittorrent-userns: failed: ${lib.concatStringsSep "; " failed}; extraOptions: ${builtins.toJSON container.extraOptions}"
else
  pkgs.runCommand "qbittorrent-userns" { } ''
    echo ${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.attrNames checks))} > $out
  ''

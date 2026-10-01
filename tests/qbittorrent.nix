# tests/qbittorrent.nix
#
# A rootless container's namespace UID/GID 0 map to the service account on the
# host. LinuxServer PUID/PGID values must therefore stay at 0 when qBittorrent
# writes NFS directories owned by that host account.
{ pkgs, self }:

let
  servers = builtins.filter (
    host: host.config.virtualisation.oci-containers.containers ? qbittorrent
  ) (builtins.attrValues self.nixosConfigurations);

  server = (builtins.head servers).config;
  environment = server.virtualisation.oci-containers.containers.qbittorrent.environment;
  preStart = server.systemd.services.podman-qbittorrent.serviceConfig.ExecStartPre;
  migratesOldIds = builtins.any (
    command: pkgs.lib.hasInfix "chown -R qbt:qbt /var/lib/qbittorrent" command
  ) preStart;

  result =
    if environment.PUID != "0" || environment.PGID != "0" then
      throw "qBittorrent must run as namespace UID/GID 0 so NFS writes use the host qbt account"
    else if !migratesOldIds then
      throw "qBittorrent must migrate files left under subordinate IDs by the old PUID mapping"
    else
      "qBittorrent rootless identity mapping is correct";
in
pkgs.runCommand "lanbat-qbittorrent" { } ''
  echo ${pkgs.lib.escapeShellArg result}
  touch $out
''

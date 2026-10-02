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
  container = server.virtualisation.oci-containers.containers.qbittorrent;
  environment = container.environment;
  preStart = server.systemd.services.podman-qbittorrent.serviceConfig.ExecStartPre;
  migratesOldIds = builtins.any (
    command: pkgs.lib.hasInfix "chown -R qbt:qbt /var/lib/qbittorrent" command
  ) preStart;
  vueTorrentVolume = "${pkgs.vuetorrent}/share/vuetorrent:/vuetorrent:ro";
  uiPrefsCommand = pkgs.lib.findFirst (
    command: pkgs.lib.hasInfix "qbittorrent-web-ui-prefs" command
  ) null preStart;

  result =
    if environment.PUID != "0" || environment.PGID != "0" then
      throw "qBittorrent must run as namespace UID/GID 0 so NFS writes use the host qbt account"
    else if !migratesOldIds then
      throw "qBittorrent must migrate files left under subordinate IDs by the old PUID mapping"
    else if !(builtins.elem vueTorrentVolume container.volumes) then
      throw "qBittorrent must mount VueTorrent read-only as its alternative web UI"
    else if uiPrefsCommand == null then
      throw "qBittorrent must configure its alternative web UI before startup"
    else
      "qBittorrent rootless identity mapping and VueTorrent configuration are correct";
in
pkgs.runCommand "lanbat-qbittorrent" { } ''
  echo ${pkgs.lib.escapeShellArg result}

  conf="$TMPDIR/qBittorrent.conf"
  cat > "$conf" <<'EOF'
  [Preferences]
  WebUI\AlternativeUIEnabled=false
  WebUI\RootFolder=/old-ui
  EOF

  ${pkgs.lib.escapeShellArg (pkgs.lib.removePrefix "+" uiPrefsCommand)} "$conf"
  grep -Fx 'WebUI\AlternativeUIEnabled=true' "$conf"
  grep -Fx 'WebUI\RootFolder=/vuetorrent' "$conf"

  touch $out
''

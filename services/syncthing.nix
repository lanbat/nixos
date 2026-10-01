# services/syncthing.nix
#
# Syncthing — continuous file synchronisation.
#
# Design
# ------
# - NixOS-native service; no container needed.
# - Web UI listens on localhost:8384; Caddy proxies sync.<domain>.
# - Web UI is protected by Authentik forward auth via Caddy (sync.<domain>).
#   Syncthing sync clients connect directly on port 22000 and never go through
#   Caddy, so forward auth does not affect them.
# - Web UI: Authentik admins only (access.groups). Sync clients are limited to
#   the devices declared in settings.
# - Sync traffic on port 22000 (TCP + UDP) is open to the LAN.
#   For devices outside the LAN (phone on mobile data, laptop elsewhere):
#     Option A — open port 22000 on your router for direct connections.
#     Option B — leave it closed and rely on Syncthing's built-in relay
#                servers (slower but no port-forwarding required).
# - Local discovery on port 21027 (UDP) is also open to the LAN.
#
# Storage split
# -------------
# Config and SQLite index stay server-local (/var/lib/syncthing).
# Devices and folders are declared per site in lanbat.services.syncthing.settings
# (see deployments/example/deploy.nix); the NixOS module overrides both, so
# ones added in the web UI disappear on restart. Personal folders go in the
# user's storage tree, one directory per folder:
#   /srv/storage/b/users/<user>/sync/<folder>/   (counts toward the XFS quota)
# A folder may also be a directory another service owns, such as the music
# library (/srv/storage/b/media/music) with qBittorrent's torrents seeded in
# place under albums/: give the syncthing user that group (settings.groups) and
# set ignorePerms so Syncthing leaves the torrent files' permissions alone.
#
# This is safe on NFSv4:
# - The database is never on NFS, so no SQLite locking issues.
# - Syncthing uses atomic writes (temp file → rename), so an NFS interruption
#   mid-sync results in a re-sync, not corruption.
# - inotify does not work over NFS: fsWatcherEnabled is disabled for every
#   folder so Syncthing falls back to polling (60s interval).
#   For the typical use case (syncing from phone/laptop → server) this is
#   irrelevant — remote changes are detected via the sync protocol, not inotify.
#
# NFS dependency
# --------------
# Syncthing is wired to Drive B (the NFS mount that holds the synced folder).
# It stops cleanly when the Pi is unreachable and restarts when storage returns.
#
# Always-on: no — depends on Pi NFS (Drive B).
{ config, lib, ... }:

let
  cfg = config.lanbat.services.syncthing.settings;

  syncthingSettings = {
    options = {
      devices = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.id = lib.mkOption {
              # Eight groups of seven base32 characters.
              type = lib.types.strMatching "[A-Z2-7]{7}(-[A-Z2-7]{7}){7}";
              description = "The device's Syncthing ID (Actions → Show ID on that device).";
            };
          }
        );
        default = { };
        description = ''
          Remote devices, by a name that folders refer to. The NixOS module
          overrides devices, so one added in the web UI is removed on restart.
        '';
      };
      groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "media" ];
        description = ''
          Supplementary groups for the syncthing user, to write folders that
          another service owns (e.g. media for a folder in the media library).
        '';
      };
      folders = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              label = lib.mkOption {
                type = lib.types.str;
                description = "Name shown in the web UI.";
              };
              path = lib.mkOption {
                type = lib.types.strMatching "/.*";
                description = "Absolute path of the folder on the server.";
              };
              type = lib.mkOption {
                type = lib.types.enum [
                  "sendreceive"
                  "sendonly"
                  "receiveonly"
                ];
                default = "sendreceive";
                description = "Syncthing folder type.";
              };
              ignorePerms = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Leave file permissions alone. Set it on folders that hold
                  files another service owns, such as torrents being seeded.
                '';
              };
              devices = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Names from settings.devices that share this folder.";
              };
            };
          }
        );
        default = { };
        description = ''
          Folders by Syncthing folder ID. Reuse the ID the other devices already
          use for the folder, so they pick the server up without re-pairing. The
          NixOS module overrides folders, so one added in the web UI is removed
          on restart.
        '';
      };
    };
  };

  undeclared = lib.concatLists (
    lib.mapAttrsToList (
      id: folder: map (device: "${id} → ${device}") (lib.filter (d: !(cfg.devices ? ${d})) folder.devices)
    ) cfg.folders
  );
in

{
  # The schema is merged into lanbat.services.syncthing.settings; checks.nix
  # rejects any key it does not declare.
  lanbat.settingsSchema.syncthing = syncthingSettings;

  assertions = [
    {
      assertion = undeclared == [ ];
      message = "lanbat.services.syncthing: folders share with devices not in settings.devices: ${lib.concatStringsSep ", " undeclared}.";
    }
  ];

  lanbat.services.syncthing = {
    subdomain = "sync";
    port = 8384;
    extraPorts = [
      21027 # local discovery
      22000 # sync
    ];
    auth = "forward-auth";
    # One server identity syncs every folder: the web UI is for admins only.
    access.groups = lib.mkDefault [ "authentik Admins" ];
    # Homepage's Syncthing widget calls /rest/* without an Authentik session.
    caddy.authBypassPaths = [ "/rest/*" ];
    tier = "workload";
    state = [ "syncthing" ];
    units = [
      "syncthing"
      "syncthing-init" # requires syncthing, so it can't start at boot
    ];
    nfs.drives = [ "b" ];
    dashboard = {
      group = "Files & Sync";
      name = "Syncthing";
      description = "Continuous file sync";
      widget = {
        type = "syncthing";
        key = {
          _secret = "SYNCTHING_API_KEY";
        };
      };
    };
  };

  services.syncthing = {
    enable = true;
    # Default user/group: syncthing (created automatically by the module).
    # Default dataDir:    /var/lib/syncthing   (server-local — config + DB)
    # Default configDir:  /var/lib/syncthing/.config/syncthing
    # Default guiAddress: 127.0.0.1:8384

    settings = {
      gui.insecureSkipHostcheck = true; # required behind a reverse proxy
      devices = lib.mapAttrs (_: device: { inherit (device) id; }) cfg.devices;
      # Every folder is on NFS, where inotify does not work: Syncthing
      # polls for local changes instead.
      folders = lib.mapAttrs (_: folder: {
        inherit (folder)
          label
          path
          type
          ignorePerms
          devices
          ;
        fsWatcherEnabled = false;
      }) cfg.folders;
    };
  };

  # For folders owned by another service's group (settings.groups).
  users.users.syncthing.extraGroups = cfg.groups;

  # Allow sync traffic from LAN.
  # Open port 22000 on your router as well if you need external device sync.
  networking.firewall = {
    allowedTCPPorts = [ 22000 ];
    allowedUDPPorts = [
      22000
      21027
    ];
  };
}

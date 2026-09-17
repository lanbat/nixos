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
# Actual synced folder data lives in each user's personal storage tree:
#   /srv/storage/b/users/<user>/sync/   (counts toward per-user XFS quota)
#
# This is safe on NFSv4:
# - The database is never on NFS, so no SQLite locking issues.
# - Syncthing uses atomic writes (temp file → rename), so an NFS interruption
#   mid-sync results in a re-sync, not corruption.
# - inotify does not work over NFS: fsWatcherEnabled is disabled for the
#   NFS-backed folder so Syncthing falls back to polling (60s interval).
#   For the typical use case (syncing from phone/laptop → server) this is
#   irrelevant — remote changes are detected via the sync protocol, not inotify.
#
# NFS dependency
# --------------
# Syncthing is wired to Drive B (the NFS mount that holds the synced folder).
# It stops cleanly when the Pi is unreachable and restarts when storage returns.
#
# Always-on: no — depends on Pi NFS (Drive B).
{ config, ... }:

let
  domain = config.lanbat.deployment.domain;
in

{
  lanbat.services.syncthing = {
    subdomain = "sync";
    port = 8384;
    extraPorts = [
      21027 # local discovery
      22000 # sync
    ];
    auth = "forward-auth";
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

      folders = {
        # CHANGE_ME: adjust id, label, and path to match your use case.
        # Additional folders can be added here or via the web UI.
        "syncthing" = {
          label = "Syncthing";
          path = "${config.lanbat.userStorage.mountOnServer}/admin/sync";
          # Disable inotify — it does not work over NFS.
          # Syncthing will poll for local changes every 60 seconds instead.
          fsWatcherEnabled = false;
          # Remote devices are added via the web UI or declared here:
          # devices = [ "device-id-goes-here" ];
        };
      };
    };
  };

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

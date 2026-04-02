# hosts/server/services/syncthing.nix
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
# Actual synced folder data lives on Pi storage:
#   /srv/storage/b/syncthing/   (Drive B — user data, alongside Nextcloud)
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

let domain = config.lanbat.domain; in

{
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
          label   = "Syncthing";
          path    = "/srv/storage/b/syncthing";
          # Disable inotify — it does not work over NFS.
          # Syncthing will poll for local changes every 60 seconds instead.
          fsWatcherEnabled = false;
          # Remote devices are added via the web UI or declared here:
          # devices = [ "device-id-goes-here" ];
        };
      };
    };
  };

  # NFS dependency — stop Syncthing if Pi Drive B disappears, restart when
  # it comes back.  The synced folder lives on Drive B.
  lanbat.nfsDependentServices."syncthing" = [ "b" ];

  # Allow sync traffic from LAN.
  # Open port 22000 on your router as well if you need external device sync.
  networking.firewall = {
    allowedTCPPorts = [ 22000 ];
    allowedUDPPorts = [ 22000 21027 ];
  };
}

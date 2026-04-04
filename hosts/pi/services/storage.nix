# hosts/pi/services/storage.nix
#
# Raspberry Pi NVMe storage — directory initialisation and NFS dependency wiring.
#
# ─────────────────────────────────────────────────────────────────────────────
# PHYSICAL LAYOUT
# ─────────────────────────────────────────────────────────────────────────────
#
#  Drive A (/dev/disk/by-id/<piStorageDriveA>):
#    LUKS2 → XFS (pquota) → /mnt/storage-a
#    Directories:
#      /mnt/storage-a/media/         — Jellyfin (movies, TV, music)
#      /mnt/storage-a/downloads/     — qBittorrent (per-user subdirs)
#      /mnt/storage-a/photos/        — Immich originals
#      /mnt/storage-a/surveillance/  — Frigate recordings
#
#  Drive B (/dev/disk/by-id/<piStorageDriveB>):
#    LUKS2 → XFS (pquota) → /mnt/storage-b
#    Directories:
#      /mnt/storage-b/nextcloud/     — Nextcloud external storage
#      /mnt/storage-b/users/         — per-user SMB home dirs
#      /mnt/storage-b/shared/        — shared SMB space
#      /mnt/storage-b/backups/       — backup target (restic repositories)
#
# ─────────────────────────────────────────────────────────────────────────────
# UNLOCK MODEL
# ─────────────────────────────────────────────────────────────────────────────
#
#  LUKS unlock and mounting are handled by modules/pi/clevis-unlock.nix.
#  That module creates:
#    storage-a-unlock.service  — unlocks + mounts /mnt/storage-a
#    storage-b-unlock.service  — unlocks + mounts /mnt/storage-b
#
#  These services run after network-online.target, retry every 5 minutes if
#  Tang is unreachable, and do NOT block boot on failure.
#
#  This file only handles what comes AFTER successful unlock:
#    - creating the required directory tree (once per new filesystem)
#    - wiring the NFS server dependency
#
# ─────────────────────────────────────────────────────────────────────────────
# XFS PROJECT QUOTAS
# ─────────────────────────────────────────────────────────────────────────────
#
#  The drives are formatted with XFS + pquota (project quotas). Setup requires
#  a one-time manual step after first formatting:
#    mount -o pquota /dev/mapper/storage-a /mnt/storage-a
#    # ... then run quota setup script
#  See docs/storage-layout.md for the full quota plan.
#
{ config, pkgs, lib, ... }:

{
  # ── Storage A initialisation ───────────────────────────────────────────────
  # Runs once after storage-a is unlocked and mounted.
  # Creates the top-level directory tree with correct permissions.
  # Wired before nfs-server.service so NFS always exports a fully-initialised tree.
  systemd.services."storage-a-init" = {
    description = "Initialise storage-a directory tree after unlock";
    # Require successful unlock (which implies the filesystem is mounted).
    requires = [ "storage-a-unlock.service" ];
    after    = [ "storage-a-unlock.service" ];
    # nfs-server.service wants this init, ensuring exports are ready before NFS starts.
    before   = [ "nfs-server.service" ];
    wantedBy = [ "nfs-server.service" ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "init-storage-a" ''
        set -e
        base=/mnt/storage-a
        install -d -m 0755 -o root   -g root    "$base/media"
        install -d -m 0755 -o root   -g root    "$base/media/movies"
        install -d -m 0755 -o root   -g root    "$base/media/tv"
        install -d -m 0755 -o root   -g root    "$base/media/music"
        install -d -m 0775 -o nobody -g nogroup "$base/downloads"
        install -d -m 0755 -o nobody -g nogroup "$base/photos"
        install -d -m 0755 -o nobody -g nogroup "$base/surveillance"
        install -d -m 0755 -o nobody -g nogroup "$base/surveillance/clips"
        install -d -m 0755 -o nobody -g nogroup "$base/surveillance/exports"
        echo "storage-a directory tree ready."
      '';
    };
  };

  # ── Storage B initialisation ───────────────────────────────────────────────
  systemd.services."storage-b-init" = {
    description = "Initialise storage-b directory tree after unlock";
    requires = [ "storage-b-unlock.service" ];
    after    = [ "storage-b-unlock.service" ];
    before   = [ "nfs-server.service" ];
    wantedBy = [ "nfs-server.service" ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "init-storage-b" ''
        set -e
        base=/mnt/storage-b
        install -d -m 0755 -o root   -g root    "$base/nextcloud"
        install -d -m 0755 -o nobody -g nogroup "$base/users"
        install -d -m 0775 -o nobody -g nogroup "$base/shared"
        install -d -m 0700 -o root   -g root    "$base/backups"
        echo "storage-b directory tree ready."
      '';
    };
  };

  # ── Packages for storage management ───────────────────────────────────────
  environment.systemPackages = with pkgs; [
    xfsprogs      # xfs_quota, xfs_admin
    cryptsetup
    clevis
  ];
}

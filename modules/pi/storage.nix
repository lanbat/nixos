# modules/pi/storage.nix
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
#      /mnt/storage-a/media/         — movies, TV, music videos (qBittorrent, Jellyfin)
#      /mnt/storage-a/photos/        — Immich originals
#      /mnt/storage-a/surveillance/  — Frigate recordings
#
#  Drive B (/dev/disk/by-id/<piStorageDriveB>):
#    LUKS2 → XFS (pquota) → /mnt/storage-b
#    Directories:
#      /mnt/storage-b/media/         — music, documentaries, ROMs, books and the rest
#                                      (qBittorrent, Jellyfin, EmulationStation)
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
{
  config,
  pkgs,
  lib,
  ...
}:

{
  # ── Storage A initialisation ───────────────────────────────────────────────
  # Runs after storage-a is unlocked and mounted, creates the top-level
  # directory tree with correct permissions, then refreshes the NFS exports so
  # the drive is served (modules/pi/nfs-exports.nix exports it once mounted).
  systemd.services."storage-a-init" = {
    description = "Initialise storage-a directory tree after unlock";
    # Require successful unlock (which implies the filesystem is mounted).
    requires = [ "storage-a-unlock.service" ];
    after = [ "storage-a-unlock.service" ];
    wantedBy = [ "storage-a-unlock.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPost = "-${pkgs.nfs-utils}/bin/exportfs -ra";
      ExecStart = pkgs.writeShellScript "init-storage-a" ''
        set -e
        base=/mnt/storage-a
        # Media, split across both drives by folder. qBittorrent on the server
        # saves here as qbt (UID 994), group media (GID 988); Jellyfin reads.
        for dir in media media/movies media/tv media/music-videos; do
          install -d -m 2775 -o 994 -g 988 "$base/$dir"
        done
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
    after = [ "storage-b-unlock.service" ];
    wantedBy = [ "storage-b-unlock.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPost = "-${pkgs.nfs-utils}/bin/exportfs -ra";
      ExecStart = pkgs.writeShellScript "init-storage-b" ''
        set -e
        base=/mnt/storage-b
        # The rest of the media, as on storage-a.
        for dir in media media/music media/documentaries media/adult media/roms \
          media/audiobooks media/books media/gym media/games media/misc; do
          install -d -m 2775 -o 994 -g 988 "$base/$dir"
        done
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
    xfsprogs # xfs_quota, xfs_admin
    cryptsetup
    clevis
  ];
}

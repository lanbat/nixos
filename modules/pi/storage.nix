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
#      /mnt/storage-b/media/adult/   — private group only (Samba + NFS gated)
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

let
  privateGid = config.users.groups.private.gid;
  mediaGid = config.users.groups.media.gid;
in
{
  # ── Storage A initialisation ───────────────────────────────────────────────
  systemd.services."storage-a-init" = {
    description = "Initialise storage-a directory tree after unlock";
    requires = [ "storage-a-unlock.service" ];
    after = [ "storage-a-unlock.service" ];
    before = [ "nfs-server.service" ];
    wantedBy = [ "nfs-server.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPost = "-${pkgs.nfs-utils}/bin/exportfs -ra";
      ExecStart = pkgs.writeShellScript "init-storage-a" ''
        set -e
        base=/mnt/storage-a
        # Media on drive A. qBittorrent saves here as qbt (UID 994), group media.
        for dir in media media/movies media/tv media/music-videos; do
          install -d -m 2775 -o 994 -g ${toString mediaGid} "$base/$dir"
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
    before = [ "nfs-server.service" ];
    wantedBy = [ "nfs-server.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPost = "-${pkgs.nfs-utils}/bin/exportfs -ra";
      ExecStart = pkgs.writeShellScript "init-storage-b" ''
        set -e
        base=/mnt/storage-b
        # General media on drive B — group media (Jellyfin, qBittorrent, Samba).
        for dir in media media/music media/documentaries media/roms \
          media/audiobooks media/books media/gym media/games media/misc; do
          install -d -m 2775 -o 994 -g ${toString mediaGid} "$base/$dir"
        done
        # Adult content is private-group only — not in Jellyfin, hidden from Samba media shares.
        install -d -m 2770 -o 994 -g ${toString privateGid} "$base/media/adult"
        chgrp ${toString privateGid} "$base/media/adult" 2>/dev/null || true
        chmod 2770 "$base/media/adult" 2>/dev/null || true
        install -d -m 0755 -o root -g root "$base/nextcloud"
        install -d -m 0755 -o nobody -g nogroup "$base/users"
        install -d -m 0775 -o nobody -g nogroup "$base/shared"
        install -d -m 0700 -o root -g root "$base/backups"
        echo "storage-b directory tree ready."
      '';
    };
  };

  environment.systemPackages = with pkgs; [
    xfsprogs
    cryptsetup
    clevis
  ];
}

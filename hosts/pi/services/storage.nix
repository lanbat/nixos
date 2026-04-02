# hosts/pi/services/storage.nix
#
# Pi storage — two LUKS-encrypted 4 TB XFS drives.
#
# Physical layout
# ---------------
# Drive A (/dev/disk/by-id/CHANGE_ME_DRIVE_A):
#   LUKS container → /dev/mapper/storage-a → XFS → /mnt/storage-a
#
#   Top-level directories:
#     /mnt/storage-a/media/         — Jellyfin (movies, TV, music)
#     /mnt/storage-a/downloads/     — qBittorrent (per-user subdirs)
#     /mnt/storage-a/photos/        — Immich originals
#     /mnt/storage-a/surveillance/  — Frigate recordings
#
# Drive B (/dev/disk/by-id/CHANGE_ME_DRIVE_B):
#   LUKS container → /dev/mapper/storage-b → XFS → /mnt/storage-b
#
#   Top-level directories:
#     /mnt/storage-b/nextcloud/     — Nextcloud external storage
#     /mnt/storage-b/users/         — per-user SMB home dirs
#     /mnt/storage-b/shared/        — shared SMB space
#     /mnt/storage-b/backups/       — backup target
#
# XFS project quotas
# ------------------
# XFS project quotas allow per-directory quotas (not just per-user).
# Setup requires a one-time manual step after formatting:
#   1. Mount the filesystem with "pquota" option (set in fileSystems below).
#   2. Run the quota setup script: pkgs/scripts/quota-setup.sh
#   3. Quotas persist in the XFS superblock across remounts.
# See docs/storage-layout.md for the full quota plan.
#
# LUKS unlock
# -----------
# Clevis/Tang handles unlock at boot (see modules/pi/clevis-unlock.nix).
# The fileSystems entries below assume the LUKS devices are already open.
# If Clevis fails, the mounts simply don't happen and NFS exports stay empty.
{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Mount points for the LUKS-unlocked XFS volumes.
  # ---------------------------------------------------------------------------
  # "noauto" — don't mount at boot; wait for Clevis to open the LUKS device.
  # "x-systemd.requires=clevis-unlock-storage-{a,b}.service" — explicit deps.
  # "pquota" — enable project quotas on the XFS filesystem.

  fileSystems."/mnt/storage-a" = {
    device  = "/dev/mapper/storage-a";
    fsType  = "xfs";
    options = [
      "noatime"
      "pquota"           # project + user quotas
      "noauto"
      "x-systemd.requires=clevis-unlock-storage-a.service"
      "x-systemd.after=clevis-unlock-storage-a.service"
    ];
  };

  fileSystems."/mnt/storage-b" = {
    device  = "/dev/mapper/storage-b";
    fsType  = "xfs";
    options = [
      "noatime"
      "pquota"
      "noauto"
      "x-systemd.requires=clevis-unlock-storage-b.service"
      "x-systemd.after=clevis-unlock-storage-b.service"
    ];
  };

  # ---------------------------------------------------------------------------
  # Create top-level directories once drives are mounted.
  # ---------------------------------------------------------------------------
  # systemd-tmpfiles runs after mounts; use a one-shot service with
  # After=mnt-storage-a.mount to be safe.
  systemd.services."storage-a-init" = {
    description = "Initialize storage-a directory tree";
    after       = [ "mnt-storage-a.mount" ];
    requires    = [ "mnt-storage-a.mount" ];
    before      = [ "nfs-server.service" ];
    wantedBy    = [ "nfs-server.service" ];
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = pkgs.writeShellScript "init-storage-a" ''
        set -e
        base=/mnt/storage-a
        install -d -m 0755 -o root    -g root    $base/media
        install -d -m 0755 -o root    -g root    $base/media/movies
        install -d -m 0755 -o root    -g root    $base/media/tv
        install -d -m 0755 -o root    -g root    $base/media/music
        install -d -m 0775 -o nobody  -g nogroup $base/downloads
        install -d -m 0755 -o nobody  -g nogroup $base/photos
        install -d -m 0755 -o nobody  -g nogroup $base/surveillance
        install -d -m 0755 -o nobody  -g nogroup $base/surveillance/clips
        install -d -m 0755 -o nobody  -g nogroup $base/surveillance/exports
        echo "storage-a initialized."
      '';
      RemainAfterExit = true;
    };
  };

  systemd.services."storage-b-init" = {
    description = "Initialize storage-b directory tree";
    after       = [ "mnt-storage-b.mount" ];
    requires    = [ "mnt-storage-b.mount" ];
    before      = [ "nfs-server.service" ];
    wantedBy    = [ "nfs-server.service" ];
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = pkgs.writeShellScript "init-storage-b" ''
        set -e
        base=/mnt/storage-b
        install -d -m 0755 -o root   -g root   $base/nextcloud
        install -d -m 0755 -o nobody -g nogroup $base/users
        install -d -m 0775 -o nobody -g nogroup $base/shared
        install -d -m 0700 -o root   -g root   $base/backups
        echo "storage-b initialized."
      '';
      RemainAfterExit = true;
    };
  };

  # ---------------------------------------------------------------------------
  # Packages needed for storage management.
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    xfsprogs      # xfs_quota, xfs_admin
    cryptsetup
    clevis
  ];
}

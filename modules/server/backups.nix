# modules/server/backups.nix
#
# Restic backup configuration — three separate tracks.
#
# ─────────────────────────────────────────────────────────────────────────────
# BACKUP TRACKS
# ─────────────────────────────────────────────────────────────────────────────
#
#  Track A — Host backup
#    Source:  /etc, /root, systemd units, admin scripts, NixOS config
#    When:    Daily; works even when LUKS layers are locked.
#    Purpose: Restore basic server bootability and admin reachability.
#    Repo:    Configured via lanbat.backups.hostRepo (restic repo URI)
#
#  Track B — Control backup
#    Source:  /mnt/control  (Tang keys + any control-plane secrets)
#    When:    Daily; runs ONLY when control-online.target is active.
#    Purpose: Preserve Tang identity. TREAT THIS BACKUP AS HIGHLY SENSITIVE.
#             Loss of Tang keys means Pi NVMe volumes cannot be unlocked
#             by Clevis and require the original LUKS passphrase instead.
#    Repo:    Configured via lanbat.backups.controlRepo
#
#  Track C — Workload backup
#    Source:  /mnt/workload  (all container state, databases, application data)
#    When:    Daily; runs ONLY when workload-online.target is active.
#    Purpose: Restore applications and hosted data.
#    Repo:    Configured via lanbat.backups.workloadRepo
#
# ─────────────────────────────────────────────────────────────────────────────
# PREREQUISITES
# ─────────────────────────────────────────────────────────────────────────────
#
#  1. Create three restic repository password secrets (agenix):
#       secrets/restic-host-password.age     — plain password string
#       secrets/restic-control-password.age  — plain password string
#       secrets/restic-workload-password.age — plain password string
#
#  2. Add them to secrets/secrets.nix (serverKeys recipients).
#
#  3. Add them to age.secrets in hosts/server/default.nix.
#
#  4. Initialise each restic repository before the first timer fires:
#       restic -r <host-repo>     init
#       restic -r <control-repo>  init
#       restic -r <workload-repo> init
#
#  5. Configure lanbat.backups.* in local.nix.
#
# ─────────────────────────────────────────────────────────────────────────────
# LUKS HEADER BACKUPS (CRITICAL — DO MANUALLY)
# ─────────────────────────────────────────────────────────────────────────────
#
#  The restic backups protect data INSIDE the LUKS volumes. The LUKS headers
#  themselves must be backed up separately. A damaged/missing LUKS header makes
#  the volume unrecoverable even with the correct passphrase or Tang keys.
#
#  Run these commands once initially and after any Clevis re-bind:
#
#    # On the server (after installation):
#    cryptsetup luksHeaderBackup /dev/sda3 --header-backup-file control-luks-header.img
#    cryptsetup luksHeaderBackup /dev/sda4 --header-backup-file workload-luks-header.img
#
#    # On the Raspberry Pi (after Clevis bind):
#    cryptsetup luksHeaderBackup /dev/disk/by-id/<driveA> --header-backup-file pi-storage-a-luks-header.img
#    cryptsetup luksHeaderBackup /dev/disk/by-id/<driveB> --header-backup-file pi-storage-b-luks-header.img
#
#  Store these .img files:
#    - Offline (USB drive stored securely, NOT connected to the network)
#    - OR encrypted separately (e.g. gpg-encrypted, stored off-site)
#    - NEVER in the same location as the server or Pi
#
#  Restoring a LUKS header:
#    cryptsetup luksHeaderRestore /dev/<device> --header-backup-file <file>
#    # After restore, re-bind Clevis if the header was corrupted:
#    clevis luks bind -d /dev/<device> tang '{"url":"http://SERVER_IP:7500"}' -y
#
# ─────────────────────────────────────────────────────────────────────────────
# RESTORE ORDER
# ─────────────────────────────────────────────────────────────────────────────
#
#  Server restore order:
#   1. Reinstall NixOS on host root (sda2) using the repo + local.nix
#   2. Restore host backup (etc, SSH keys, systemd units) from Track A
#   3. Restore control LUKS header if needed; open control LUKS
#   4. Restore /mnt/control from Track B → Tang keys restored
#   5. Start Tang; verify: curl http://127.0.0.1:7500/adv
#   6. Restore workload LUKS header if needed; open workload LUKS
#   7. Restore /mnt/workload from Track C → all service data restored
#   8. systemctl start workload-online.target
#
#  Raspberry Pi restore order:
#   1. Re-flash SD card with NixOS, deploy config
#   2. Restore Pi NVMe LUKS header if needed (see above)
#   3. Re-bind Clevis to Tang (server must be up with control layer unlocked)
#   4. Reboot Pi or: systemctl start storage-a-unlock storage-b-unlock
#   5. Restore data into /mnt/storage-a and /mnt/storage-b from Pi backup
#
# ─────────────────────────────────────────────────────────────────────────────
# RESTORE TESTING
# ─────────────────────────────────────────────────────────────────────────────
#
#  Monthly: verify workload backup integrity:
#    restic -r <workload-repo> check
#
#  Quarterly: restore to a test path and verify data:
#    restic -r <workload-repo> restore latest --target /tmp/restore-test
#    ls /tmp/restore-test/mnt/workload/postgresql/
#    rm -rf /tmp/restore-test
#
{ config, lib, pkgs, ... }:

let
  cfg = config.lanbat;

  # Retention policy — applied to all repositories.
  pruneArgs = [
    "--keep-daily"   "7"
    "--keep-weekly"  "4"
    "--keep-monthly" "6"
    "--keep-yearly"  "2"
  ];

  mkResticService = { name, repoPath, passwordFile, paths, extraRequires ? [], extraAfter ? [] }: {
    # systemd service that runs restic backup.
    # Credentials (repo password) come from the agenix-decrypted file.
    "${name}-backup" = {
      description = "Restic ${name} backup";
      requires    = [ "network-online.target" ] ++ extraRequires;
      after       = [ "network-online.target" ] ++ extraAfter;
      # Service does not start at boot — it is triggered by the timer.
      serviceConfig = {
        Type = "oneshot";
        # Load the restic repo password from the agenix secret.
        # File must contain a single line: the restic password.
        EnvironmentFile = passwordFile;
        ExecStart = pkgs.writeShellScript "${name}-backup-run" ''
          set -euo pipefail
          REPO="${repoPath}"
          export RESTIC_PASSWORD="$RESTIC_PASSWORD"  # from EnvironmentFile

          echo "=== restic ${name} backup: starting ==="
          date

          # Initialise repo if it doesn't exist yet.
          if ! ${pkgs.restic}/bin/restic -r "$REPO" snapshots >/dev/null 2>&1; then
            echo "Initialising restic repository at $REPO..."
            ${pkgs.restic}/bin/restic -r "$REPO" init
          fi

          # Run backup.
          ${pkgs.restic}/bin/restic -r "$REPO" backup \
            --one-file-system \
            --exclude-caches \
            ${lib.concatStringsSep " " (map (p: "'${p}'") paths)}

          # Prune old snapshots.
          ${pkgs.restic}/bin/restic -r "$REPO" forget \
            --prune \
            ${lib.concatStringsSep " " pruneArgs}

          # Verify repository integrity.
          ${pkgs.restic}/bin/restic -r "$REPO" check

          echo "=== restic ${name} backup: done ==="
        '';
      };
    };
  };

  mkResticTimer = name: schedule: {
    "${name}-backup" = {
      description = "Restic ${name} backup timer";
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar         = schedule;
        RandomizedDelaySec = "30min";
        Persistent         = true;  # catch up if system was off
      };
    };
  };

in
{
  environment.systemPackages = [ pkgs.restic ];

  # ── Track A: Host backup ───────────────────────────────────────────────────
  # Runs regardless of LUKS state. Backs up the host OS layer.
  # Restic repo must be configured. Local backup to /mnt/storage-b/backups/host
  # would require Pi NFS — for host backup, prefer an external or offsite repo.
  #
  # TODO: create secrets/restic-host-password.age and set hostBackupRepo in local.nix.
  # Uncomment the block below once the secret and repo are configured.
  #
  # systemd.services = mkResticService {
  #   name         = "host";
  #   repoPath     = cfg.backups.hostRepo;           # add this option to settings.nix
  #   passwordFile = config.age.secrets.restic-host-password.path;
  #   paths        = [
  #     "/etc"
  #     "/root"
  #     "/var/lib/nixos"
  #     "/etc/nixos"   # the cloned config repo
  #   ];
  # };
  # systemd.timers = mkResticTimer "host" "02:00";

  # ── Track B: Control backup ────────────────────────────────────────────────
  # Runs ONLY when control-online.target is active.
  # TREAT AS HIGHLY SENSITIVE — backs up Tang key material.
  # Store the restic repo itself off-server (S3, B2, etc.) or on offline media.
  #
  # TODO: create secrets/restic-control-password.age and configure controlBackupRepo.
  #
  # systemd.services = mkResticService {
  #   name         = "control";
  #   repoPath     = cfg.backups.controlRepo;
  #   passwordFile = config.age.secrets.restic-control-password.path;
  #   paths        = [ "/mnt/control" ];
  #   extraRequires = [ "control-online.target" ];
  #   extraAfter    = [ "control-online.target" ];
  # };
  # systemd.timers = mkResticTimer "control" "03:00";

  # ── Track C: Workload backup ───────────────────────────────────────────────
  # Runs ONLY when workload-online.target is active.
  # For PostgreSQL: dump databases before backup for consistency.
  # The timer runs daily at 03:30 (after control backup window).
  #
  # TODO: create secrets/restic-workload-password.age and configure workloadBackupRepo.
  #
  # systemd.services = mkResticService {
  #   name         = "workload";
  #   repoPath     = cfg.backups.workloadRepo;
  #   passwordFile = config.age.secrets.restic-workload-password.path;
  #   paths        = [ "/mnt/workload" ];
  #   extraRequires = [ "workload-online.target" ];
  #   extraAfter    = [ "workload-online.target" ];
  # };
  # systemd.timers = mkResticTimer "workload" "03:30";

  # ── PostgreSQL dump helper (run before workload backup) ────────────────────
  # Dumps all databases to /mnt/workload/postgresql-dumps/ for consistent backup.
  #
  # systemd.services."postgresql-dump" = {
  #   description = "Dump all PostgreSQL databases for backup";
  #   requires = [ "workload-online.target" "postgresql.service" ];
  #   after    = [ "workload-online.target" "postgresql.service" ];
  #   before   = [ "workload-backup.service" ];
  #   serviceConfig = {
  #     Type = "oneshot";
  #     User = "postgres";
  #     ExecStart = pkgs.writeShellScript "pg-dump-all" ''
  #       set -euo pipefail
  #       DUMPDIR=/mnt/workload/postgresql-dumps
  #       mkdir -p "$DUMPDIR"
  #       for db in authentik nextcloud bitmagnet; do
  #         pg_dump -Fc "$db" > "$DUMPDIR/$db-$(date +%Y%m%d).dump"
  #       done
  #       # Prune dumps older than 7 days.
  #       find "$DUMPDIR" -name "*.dump" -mtime +7 -delete
  #     '';
  #   };
  # };
}

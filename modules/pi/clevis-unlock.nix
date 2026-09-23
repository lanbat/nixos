# modules/pi/clevis-unlock.nix
#
# Post-boot Clevis/Tang unlock for the Raspberry Pi's NVMe storage drives, one
# unit per key of hosts.<key>.storage.drives.
#
# ─────────────────────────────────────────────────────────────────────────────
# DESIGN: POST-BOOT UNLOCK (NOT INITRAMFS)
# ─────────────────────────────────────────────────────────────────────────────
#
#  The NVMe drives are SECONDARY storage volumes, not the root/boot device.
#  The Raspberry Pi boots from the SD card regardless of Tang availability.
#  Therefore, LUKS unlock happens after boot as regular systemd services, not
#  in the initramfs. This avoids initramfs networking complexity and allows
#  clean retry without affecting boot success.
#
# ─────────────────────────────────────────────────────────────────────────────
# BOOT SEQUENCE
# ─────────────────────────────────────────────────────────────────────────────
#
#  SD card boots → network comes up → one storage-<drive>-unlock service per
#  drive starts (storage-a-unlock and storage-b-unlock for drives a and b) →
#  each service tries Clevis/Tang unlock:
#
#    IF Tang reachable (server control layer unlocked):
#      → LUKS open succeeds → drive mounts → NFS exports become populated
#
#    IF Tang unreachable (server still locked / offline):
#      → LUKS open fails → service exits with error
#      → systemd retries automatically every 5 minutes (storage-<drive>-unlock.timer)
#      → boot continues; SD-card OS and non-NVMe services remain fully functional
#      → once the server admin unlocks the control layer, next retry succeeds
#
# ─────────────────────────────────────────────────────────────────────────────
# MANUAL RETRY
# ─────────────────────────────────────────────────────────────────────────────
#
#  If you need to trigger retry immediately (rather than waiting 5 minutes):
#    systemctl start storage-a-unlock.service
#    systemctl start storage-b-unlock.service
#
#  To check unlock status:
#    systemctl status storage-a-unlock storage-b-unlock
#    lsblk
#
# ─────────────────────────────────────────────────────────────────────────────
# KNOWN LIMITATION — ALREADY-UNLOCKED VOLUMES
# ─────────────────────────────────────────────────────────────────────────────
#
#  Tang/Clevis gating controls UNLOCK-AT-BOOT behaviour only. It does NOT
#  retroactively re-lock NVMe volumes that are already mounted on a RUNNING
#  Raspberry Pi if the server is subsequently rebooted or the control LUKS
#  layer is locked while the Pi is running.
#
#  If the server is rebooted (losing Tang) while the Pi's drives are already
#  unlocked and mounted, those drives REMAIN unlocked and mounted on the Pi
#  until the Pi itself is rebooted or the drives are explicitly closed.
#
#  Operationally: if you need to fully revoke Pi storage access, you must also
#  reboot the Raspberry Pi (or manually umount and cryptsetup luksClose on it).
#  Locking the server's Tang is NOT sufficient on its own for a running Pi.
#
# ─────────────────────────────────────────────────────────────────────────────
# OPTIONAL HARDENING (not implemented by default)
# ─────────────────────────────────────────────────────────────────────────────
#
#  For stronger unlock requirements, Clevis SSS (shamir secret sharing) can
#  combine Tang with a local TPM2 factor. This requires a TPM2 device on the
#  Pi (the Pi 5 has no onboard TPM but an SPI module can be added).
#
#  Binding command (SSS with Tang + TPM2, 2-of-2):
#    clevis luks bind -d /dev/disk/by-id/<drive> sss \
#      '{"t":2,"pins":{"tang":{"url":"http://SERVER_IP:7500"},"tpm2":{}}}'
#
#  With SSS: BOTH Tang AND the local TPM2 must be present. Removing the drive
#  to a different machine (no TPM) prevents unlock even if Tang is reachable.
#
#  The default binding uses Tang alone (simpler, sufficient for this design).
#
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.lanbat;
  host = cfg.hosts.${cfg.hostKey};
  storageDrives = host.storage.drives;

  # The drives are named by their keys in hosts.<key>.storage.drives, and each
  # key names everything derived from it: drive "a" is unlocked by
  # storage-a-unlock into /dev/mapper/storage-a and mounted on /mnt/storage-a.
  # lib/validate-deploy.nix keeps the keys to lowercase letters and digits so
  # they are safe in all three.
  driveNames = lib.attrNames storageDrives;
  mapperName = drive: "storage-${drive}";
  mountPoint = drive: "/mnt/storage-${drive}";
  unlockUnit = drive: "storage-${drive}-unlock";

  # Unlock + mount script for one drive.
  # Arguments: $1 = by-id path, $2 = mapper name, $3 = mount point.
  unlockScript = pkgs.writeShellScript "clevis-unlock-drive" ''
    set -euo pipefail
    # clevis-decrypt-tang calls curl and jose from PATH, which a systemd
    # service doesn't provide.
    export PATH=${
      lib.makeBinPath [
        pkgs.curl
        pkgs.jose
        pkgs.cryptsetup
        pkgs.util-linux
      ]
    }:$PATH
    DRIVE_ID="$1"
    MAPPER="$2"
    MOUNTPOINT="$3"

    DRIVE="/dev/disk/by-id/$DRIVE_ID"

    # Verify the drive device exists.
    if [ ! -b "$DRIVE" ]; then
      echo "ERROR: drive not found: $DRIVE" >&2
      exit 1
    fi

    # The LUKS container is either the whole disk or a partition on it. Try the
    # whole disk first, then each partition in order, and take the first that is
    # really a LUKS device. deploy.nix keeps naming the whole disk because
    # modules/pi/telegraf.nix reads SMART from that same path.
    LUKS_DEV=""
    if cryptsetup isLuks "$DRIVE"; then
      LUKS_DEV="$DRIVE"
    else
      for part in "$DRIVE"-part*; do
        [ -b "$part" ] || continue
        if cryptsetup isLuks "$part"; then
          LUKS_DEV="$part"
          break
        fi
      done
    fi

    if [ -z "$LUKS_DEV" ]; then
      echo "ERROR: no LUKS container on $DRIVE (checked the whole disk and its partitions)" >&2
      exit 1
    fi

    # Open the LUKS volume via Clevis/Tang (idempotent — skip if already open).
    if [ ! -e "/dev/mapper/$MAPPER" ]; then
      echo "Attempting Clevis unlock: $LUKS_DEV → /dev/mapper/$MAPPER"
      # clevis luks unlock contacts Tang over the network.
      # If Tang is unreachable, this exits non-zero and we retry.
      ${pkgs.clevis}/bin/clevis luks unlock -d "$LUKS_DEV" -n "$MAPPER"
      echo "Clevis unlock succeeded: /dev/mapper/$MAPPER"
    else
      echo "INFO: /dev/mapper/$MAPPER already open, skipping unlock."
    fi

    # Mount the filesystem (idempotent — skip if already mounted).
    if ! ${pkgs.util-linux}/bin/mountpoint -q "$MOUNTPOINT"; then
      echo "Mounting /dev/mapper/$MAPPER → $MOUNTPOINT"
      mount /dev/mapper/$MAPPER "$MOUNTPOINT"
      echo "Mounted $MOUNTPOINT."
    else
      echo "INFO: $MOUNTPOINT already mounted."
    fi
  '';

  # Stop script — unmount and close LUKS for one drive.
  stopScript = pkgs.writeShellScript "clevis-stop-drive" ''
    set -euo pipefail
    MAPPER="$1"
    MOUNTPOINT="$2"

    if ${pkgs.util-linux}/bin/mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
      echo "Unmounting $MOUNTPOINT..."
      ${pkgs.util-linux}/bin/umount -l "$MOUNTPOINT" \
        || ${pkgs.util-linux}/bin/umount "$MOUNTPOINT"
    fi
    if [ -e "/dev/mapper/$MAPPER" ]; then
      echo "Closing LUKS mapper: $MAPPER"
      ${pkgs.cryptsetup}/bin/cryptsetup luksClose "$MAPPER" || true
    fi
  '';

in
{
  # ── Required packages ──────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    clevis
    tang # provides jose, needed by clevis
    tpm2-tools # for optional TPM2 hardening variant
    cryptsetup
  ];

  # ── Mount point stubs ──────────────────────────────────────────────────────
  # These directories exist on the SD card. They are empty when the NVMe drives
  # are locked; the unlock services mount the filesystems here on success.
  systemd.tmpfiles.rules = map (drive: "d ${mountPoint drive} 0755 root root -") driveNames;

  # ── Unlock services, one per drive ─────────────────────────────────────────
  systemd.services = lib.listToAttrs (
    map (
      drive:
      lib.nameValuePair (unlockUnit drive) {
        description = "Clevis/Tang unlock and mount of NVMe storage drive ${lib.toUpper drive}";

        # Run after network is online — Clevis needs to reach Tang.
        after = [
          "network-online.target"
          "systemd-udevd.service"
        ];
        wants = [ "network-online.target" ];
        # Attempt at boot; place in multi-user so NFS can depend on it.
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Retried by the timer of the same name (see below).
          ExecStart = "${unlockScript} ${storageDrives.${drive}} ${mapperName drive} ${mountPoint drive}";
          ExecStop = "${stopScript} ${mapperName drive} ${mountPoint drive}";
        };
      }
    ) driveNames
  );

  # ── Retries ────────────────────────────────────────────────────────────────
  # A failed unlock (Tang unreachable, drive not bound yet) is retried every
  # 5 minutes until it succeeds. This is a timer rather than
  # Restart=on-failure: a restarting oneshot keeps its start job queued, which
  # holds up multi-user.target at boot and `nixos-rebuild switch` until the
  # drive unlocks.
  systemd.timers = lib.genAttrs (map unlockUnit driveNames) (_: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnActiveSec = "5min";
      OnUnitInactiveSec = "5min";
    };
  });

  # ── No initramfs changes needed ────────────────────────────────────────────
  # The NVMe drives are not the boot device. Initramfs networking is not
  # required for this unlock design. The SD card boot is completely independent.
}

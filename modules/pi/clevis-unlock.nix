# modules/pi/clevis-unlock.nix
#
# Post-boot Clevis/Tang unlock for the Raspberry Pi's two NVMe storage drives.
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
#  SD card boots → network comes up → storage-a-unlock and storage-b-unlock
#  services start → each service tries Clevis/Tang unlock:
#
#    IF Tang reachable (server control layer unlocked):
#      → LUKS open succeeds → drive mounts → NFS exports become populated
#
#    IF Tang unreachable (server still locked / offline):
#      → LUKS open fails → service exits with error
#      → systemd retries automatically every 5 minutes (Restart=on-failure)
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
{ config, pkgs, lib, ... }:

let
  cfg = config.lanbat;

  # Unlock + mount script for one drive.
  # Arguments: $1 = by-id path, $2 = mapper name, $3 = mount point.
  unlockScript = pkgs.writeShellScript "clevis-unlock-drive" ''
    set -euo pipefail
    DRIVE_ID="$1"
    MAPPER="$2"
    MOUNTPOINT="$3"

    DRIVE="/dev/disk/by-id/$DRIVE_ID"

    # Verify the drive device exists.
    if [ ! -b "$DRIVE" ]; then
      echo "ERROR: drive not found: $DRIVE" >&2
      exit 1
    fi

    # Open the LUKS volume via Clevis/Tang (idempotent — skip if already open).
    if [ ! -e "/dev/mapper/$MAPPER" ]; then
      echo "Attempting Clevis unlock: $DRIVE → /dev/mapper/$MAPPER"
      # clevis luks unlock contacts Tang over the network.
      # If Tang is unreachable, this exits non-zero and we retry.
      ${pkgs.clevis}/bin/clevis luks unlock -d "$DRIVE" -n "$MAPPER"
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
      umount -l "$MOUNTPOINT" || umount "$MOUNTPOINT"
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
    tang        # provides jose, needed by clevis
    tpm2-tools  # for optional TPM2 hardening variant
    cryptsetup
  ];

  # ── Mount point stubs ──────────────────────────────────────────────────────
  # These directories exist on the SD card. They are empty when the NVMe drives
  # are locked; the unlock services mount the filesystems here on success.
  systemd.tmpfiles.rules = [
    "d /mnt/storage-a 0755 root root -"
    "d /mnt/storage-b 0755 root root -"
  ];

  # ── Storage A unlock service ───────────────────────────────────────────────
  systemd.services."storage-a-unlock" = {
    description = "Clevis/Tang unlock and mount of NVMe storage drive A";

    # Run after network is online — Clevis needs to reach Tang.
    after   = [ "network-online.target" "systemd-udevd.service" ];
    wants   = [ "network-online.target" ];
    # Attempt at boot; place in multi-user so NFS can depend on it.
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;

      # Retry every 5 minutes on failure (Tang unreachable).
      # systemd.unit man page: Restart=on-failure works for oneshot services.
      Restart    = "on-failure";
      RestartSec = "5min";
      # Limit restart storm (e.g. Tang is permanently gone):
      # After StartLimitBurst failures in StartLimitIntervalSec, stop retrying.
      StartLimitBurst        = 288; # 288 × 5min = 24 hours of retries
      StartLimitIntervalSec  = "25h";

      ExecStart = "${unlockScript} ${cfg.piStorageDriveA} storage-a /mnt/storage-a";
      ExecStop  = "${stopScript} storage-a /mnt/storage-a";
    };
  };

  # ── Storage B unlock service ───────────────────────────────────────────────
  systemd.services."storage-b-unlock" = {
    description = "Clevis/Tang unlock and mount of NVMe storage drive B";

    after    = [ "network-online.target" "systemd-udevd.service" ];
    wants    = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      Restart    = "on-failure";
      RestartSec = "5min";
      StartLimitBurst        = 288;
      StartLimitIntervalSec  = "25h";

      ExecStart = "${unlockScript} ${cfg.piStorageDriveB} storage-b /mnt/storage-b";
      ExecStop  = "${stopScript} storage-b /mnt/storage-b";
    };
  };

  # ── No initramfs changes needed ────────────────────────────────────────────
  # The NVMe drives are not the boot device. Initramfs networking is not
  # required for this unlock design. The SD card boot is completely independent.
}

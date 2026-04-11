# modules/server/secure-layers.nix
#
# Three-layer server security design.
#
# ─────────────────────────────────────────────────────────────────────────────
# DESIGN SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
#
#  Layer 1 — Host (always available after boot)
#    /dev/sda2 → ext4 → /
#    Contains: NixOS, SSH, networking, firewall, admin tools, systemd units.
#    Does NOT contain: Tang keys, container data, databases, application state.
#    The server boots here and becomes SSH-reachable without any passphrase.
#
#  Layer 2 — Control LUKS (locked at boot, manually unlocked)
#    /dev/sda3 → LUKS2 → ext4 → /mnt/control
#    Contains: /mnt/control/tang/ (Tang key material)
#    A bind mount makes /mnt/control/tang available as /var/lib/tang.
#    Tang only starts after this layer is mounted.
#
#  Layer 3 — Workload LUKS (locked at boot, manually unlocked)
#    /dev/sda4 → LUKS2 → ext4 → /mnt/workload
#    Contains: all container state, databases, application data.
#    Bind mounts overlay /var/lib/* paths with workload subdirectories.
#    All application services start only after this layer is mounted.
#
# ─────────────────────────────────────────────────────────────────────────────
# BOOT SEQUENCE
# ─────────────────────────────────────────────────────────────────────────────
#
#  boot  →  host OS up  →  SSH reachable  →  both LUKS layers locked
#
#  admin unlocks control:  cryptsetup luksOpen /dev/sda3 control
#                          systemctl start control-online.target
#                          → Tang socket starts → Pi can unlock its NVMe drives
#
#  admin unlocks workload: cryptsetup luksOpen /dev/sda4 workload
#                          systemctl start workload-online.target
#                          → bind mounts activate → all services start
#
# ─────────────────────────────────────────────────────────────────────────────
# THREAT MODEL NOTE
# ─────────────────────────────────────────────────────────────────────────────
#
#  This design gates Tang availability on manual passphrase entry. Someone
#  who reboots the server without knowing the control passphrase gets SSH
#  access to an empty host but cannot reach Tang, cannot unlock the Pi's
#  NVMe drives, and cannot access workload data.
#
#  The host root (sda2) is NOT LUKS-encrypted. SSH host keys live there.
#  This is an intentional trade-off: the server must be remotely administrable
#  after reboot without physical presence. Disk-level confidentiality of the
#  host root (OS, config) is not provided by this design.
#
{ config, lib, pkgs, ... }:

let
  cfg = config.lanbat;

  # ── Helper: admin script ────────────────────────────────────────────────────
  adminScript = name: body: pkgs.writeShellScriptBin name ''
    set -euo pipefail
    ${body}
  '';

  # ── Systemd mount unit name from filesystem path ────────────────────────────
  # /mnt/control → mnt-control.mount
  # /var/lib/tang → var-lib-tang.mount
  mountUnit = path:
    "${lib.replaceStrings ["/"] ["-"] (lib.removePrefix "/" path)}.mount";

in
{
  # ── Stub mount-point directories on host root ─────────────────────────────
  # These exist on the unencrypted root so the mount points are always present.
  # They are empty when the LUKS layers are locked — bind mounts or filesystem
  # mounts overlay them when the layers are unlocked.
  # Mode 0 prevents accidental writes into unmounted stubs.
  systemd.tmpfiles.rules = [
    # Control and workload mount points
    "d /mnt/control   0000 root root -"
    "d /mnt/workload  0000 root root -"
    # Tang state directory stub (overlaid by control bind mount)
    "d /var/lib/tang  0000 root root -"
    # Workload service data directory stubs (overlaid by workload bind mounts).
    # Mode 0000 = inaccessible when workload is locked; bind mount overlays when unlocked.
    # Only workload-gated services get stubs here.
    # Always-on services (caddy, postgresql, authentik, hass, grafana, influxdb2,
    # mosquitto, frigate, containers) manage their own /var/lib/* directories
    # and are NOT listed here.
    "d /var/lib/nextcloud   0000 root root -"
    "d /var/lib/immich      0000 root root -"
    "d /var/lib/jellyfin    0000 root root -"
    "d /var/lib/vaultwarden 0000 root root -"
    "d /var/lib/syncthing   0000 root root -"
    "d /var/lib/qbittorrent 0000 root root -"
    "d /var/lib/bitmagnet   0000 root root -"
    "d /var/lib/samba       0000 root root -"
  ];

  # ── No /etc/crypttab ─────────────────────────────────────────────────────
  # Intentionally absent.  The systemd-cryptsetup-generator reads crypttab
  # and creates systemd-cryptsetup@*.service units; even with "noauto",
  # implicit device dependencies (dev-mapper-*.device) from the filesystem
  # entries can pull them into the boot transaction on some systemd versions.
  # The admin scripts (unlock-control, unlock-workload) use cryptsetup
  # luksOpen directly, so the generator is not needed.

  # ── /mnt/control filesystem ──────────────────────────────────────────────
  # noauto: unit is NOT included in local-fs.target; will not mount at boot.
  # Requires /dev/mapper/control to exist (created by cryptsetup luksOpen).
  fileSystems."/mnt/control" = {
    device  = "/dev/mapper/control";
    fsType  = "ext4";
    options = [ "noauto" "noatime" "x-systemd.idle-timeout=0" ];
  };

  # ── /mnt/workload filesystem ──────────────────────────────────────────────
  fileSystems."/mnt/workload" = {
    device  = "/dev/mapper/workload";
    fsType  = "ext4";
    options = [ "noauto" "noatime" "x-systemd.idle-timeout=0" ];
  };

  # ── /var/lib/tang bind mount (control → standard Tang path) ───────────────
  # Tang's NixOS module stores keys in /var/lib/tang.
  # We bind-mount /mnt/control/tang there so Tang keys live on the control
  # LUKS layer and are unavailable until that layer is manually unlocked.
  #
  # This mount unit (var-lib-tang.mount) requires mnt-control.mount.
  # If control is not mounted, this bind mount fails, and Tang cannot start.
  fileSystems."/var/lib/tang" = {
    device  = "/mnt/control/tang";
    fsType  = "none";
    options = [
      "bind"
      "noauto"
      # Require /mnt/control to be mounted first.
      "x-systemd.requires=${mountUnit "/mnt/control"}"
      "x-systemd.after=${mountUnit "/mnt/control"}"
    ];
  };

  # ── control-online.target ─────────────────────────────────────────────────
  # Activated after the control LUKS layer is mounted and the Tang bind mount
  # is active. Starting this target brings Tang online.
  # This target is NOT started at boot — it is started manually by unlock-control.
  systemd.targets."control-online" = {
    description = "Control LUKS layer mounted and Tang available";
    # Require both the ext4 mount and the Tang bind mount.
    requires = [
      (mountUnit "/mnt/control")
      (mountUnit "/var/lib/tang")
    ];
    after = [
      (mountUnit "/mnt/control")
      (mountUnit "/var/lib/tang")
    ];
    # wantedBy intentionally omitted — not started at boot.
  };

  # ── Tang socket: gated on control-online.target ───────────────────────────
  # Tang is socket-activated. The socket must not start until control-online
  # is active (which requires the Tang bind mount to be in place).
  # ConditionPathIsMountPoint is a runtime safety check: even if the socket is
  # somehow started before the bind mount, Tang will refuse to serve keys.
  systemd.sockets.tangd = {
    # Remove the default multi-user.target and sockets.target association.
    # Tang only starts as part of control-online.target.
    wantedBy = lib.mkForce [ "control-online.target" ];
    # Ensure correct ordering and stop propagation.
    after    = [ "control-online.target" ];
    partOf   = [ "control-online.target" ];
    # Safety: refuse to activate if /var/lib/tang is not an active mount point.
    unitConfig.ConditionPathIsMountPoint = "/var/lib/tang";
  };

  # Tang per-connection service inherits ordering from socket activation.
  # Add the bind mount condition as a hard requirement.
  systemd.services."tangd@" = {
    after   = [ (mountUnit "/var/lib/tang") ];
    requires = [ (mountUnit "/var/lib/tang") ];
    unitConfig.ConditionPathIsMountPoint = "/var/lib/tang";
  };

  # ── Admin scripts ─────────────────────────────────────────────────────────
  environment.systemPackages = [

    # unlock-control: open control LUKS, mount it, start Tang.
    (adminScript "unlock-control" ''
      CONTROL_UUID="${cfg.serverControlLuksUuid}"
      echo "=== unlock-control: opening control LUKS layer ==="
      echo
      if [ -e /dev/mapper/control ]; then
        echo "INFO: /dev/mapper/control already exists, skipping luksOpen."
      else
        cryptsetup luksOpen /dev/disk/by-uuid/"$CONTROL_UUID" control
      fi
      echo "Mounting /mnt/control and activating control-online.target..."
      systemctl start control-online.target
      echo
      echo "Tang socket status:"
      systemctl status tangd.socket --no-pager --lines=5 || true
      echo
      echo "Tang health check:"
      curl -sf http://127.0.0.1:7500/adv | ${pkgs.jq}/bin/jq -r '.keys[].alg' \
        && echo "Tang: OK" \
        || echo "Tang: not yet responding (may take a moment)"
    '')

    # lock-control: stop Tang, unmount control, close LUKS.
    # Run lock-workload first — Tang must stay available until Pi is prepared.
    (adminScript "lock-control" ''
      echo "=== lock-control: stopping Tang and locking control layer ==="
      echo
      echo "Stopping Tang socket (this makes Tang immediately unavailable)..."
      echo "WARNING: After this, the Raspberry Pi cannot auto-unlock its drives."
      echo "         Ensure Pi drives are already locked or you have a manual plan."
      read -r -p "Continue? [y/N] " confirm
      [[ "$confirm" == [yY] ]] || { echo "Aborted."; exit 1; }
      systemctl stop tangd.socket 2>/dev/null || true
      systemctl stop "tangd@*.service" 2>/dev/null || true
      systemctl stop control-online.target 2>/dev/null || true
      if mountpoint -q /var/lib/tang; then
        umount /var/lib/tang
      fi
      if mountpoint -q /mnt/control; then
        umount /mnt/control
      fi
      if [ -e /dev/mapper/control ]; then
        cryptsetup luksClose control
        echo "Control LUKS closed."
      else
        echo "INFO: /dev/mapper/control not found, already closed."
      fi
    '')

  ];
}

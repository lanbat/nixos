# modules/server/control-layer.nix
#
# Three-layer server security design, and the control layer itself.
#
# ─────────────────────────────────────────────────────────────────────────────
# DESIGN SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
#
#  Layer 1 — Host (always available after boot)
#    LVM root → ext4 → /   (hosts/server/disk.nix)
#    NixOS, SSH, networking, admin tools, always-on services.
#    The server boots here and is SSH-reachable without any passphrase.
#
#  Layer 2 — Control LUKS (locked at boot, unlocked manually)
#    LVM control → LUKS2 → ext4 → /mnt/control
#    Holds /mnt/control/tang (Tang key material), bind-mounted to /var/lib/tang.
#    Tang only starts after this layer is mounted.
#
#  Layer 3 — Workload LUKS (locked at boot, unlocked manually)
#    LVM workload → LUKS2 → ext4 → /mnt/workload
#    State of workload-tier services, bind-mounted over /var/lib/<name>.
#    See modules/wiring/workload-gate.nix.
#
# ─────────────────────────────────────────────────────────────────────────────
# BOOT SEQUENCE
# ─────────────────────────────────────────────────────────────────────────────
#
#  boot → host OS up → SSH reachable → both LUKS layers locked
#  unlock-control  → Tang socket starts → the Pi can unlock its drives
#  unlock-workload → bind mounts activate → workload services start
#
# ─────────────────────────────────────────────────────────────────────────────
# THREAT MODEL NOTE
# ─────────────────────────────────────────────────────────────────────────────
#
#  Tang availability is gated on a manual passphrase. Someone who reboots the
#  server without it gets an empty host: no Tang, so no Pi drive unlock, and
#  no workload data.
#
#  The host root is NOT encrypted; SSH host keys live there. This is a
#  deliberate trade-off so the server stays remotely administrable after a
#  reboot.
#
#  There is no /etc/crypttab: the unlock scripts call cryptsetup directly, so
#  systemd-cryptsetup-generator can't pull the volumes into the boot
#  transaction.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  adminScript =
    name: body:
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      ${body}
    '';
in
{
  options.lanbat.layers.controlDevice = lib.mkOption {
    type = lib.types.str;
    example = "/dev/lanbat/control";
    description = "Block device holding the control LUKS volume. Set by the host's disk layout.";
  };

  config = {
    # Mount-point stubs on the host root, closed while the layer is locked.
    systemd.tmpfiles.rules = [
      "d /mnt/control :0000 :root :root -"
      "d /var/lib/tang :0000 :root :root -"
    ];

    fileSystems."/mnt/control" = {
      device = "/dev/mapper/control";
      fsType = "ext4";
      options = [
        "noauto"
        "noatime"
        "x-systemd.idle-timeout=0"
      ];
    };

    # Tang's keys live on the control layer and appear at Tang's usual path.
    fileSystems."/var/lib/tang" = {
      device = "/mnt/control/tang";
      fsType = "none";
      options = [
        "bind"
        "noauto"
        "x-systemd.requires=mnt-control.mount"
        "x-systemd.after=mnt-control.mount"
      ];
    };

    systemd.targets.control-online = {
      description = "Control LUKS layer mounted and Tang available";
      requires = [
        "mnt-control.mount"
        "var-lib-tang.mount"
      ];
      after = [
        "mnt-control.mount"
        "var-lib-tang.mount"
      ];
      # No wantedBy: unlock-control starts it.
    };

    # Tang is socket-activated; the socket only starts with control-online.target.
    # ConditionPathIsMountPoint refuses to serve keys without the bind mount.
    systemd.sockets.tangd = {
      wantedBy = lib.mkForce [ "control-online.target" ];
      after = [ "control-online.target" ];
      partOf = [ "control-online.target" ];
      unitConfig.ConditionPathIsMountPoint = "/var/lib/tang";
    };

    systemd.services."tangd@" = {
      after = [ "var-lib-tang.mount" ];
      requires = [ "var-lib-tang.mount" ];
      unitConfig.ConditionPathIsMountPoint = "/var/lib/tang";
    };

    environment.systemPackages = [
      # unlock-control: open the control LUKS volume, mount it, start Tang.
      (adminScript "unlock-control" ''
        echo "=== unlock-control: opening control LUKS layer ==="
        echo
        if [ -e /dev/mapper/control ]; then
          echo "INFO: /dev/mapper/control already exists, skipping luksOpen."
        else
          cryptsetup luksOpen ${config.lanbat.layers.controlDevice} control
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
      (adminScript "lock-control" ''
        echo "=== lock-control: stopping Tang and locking control layer ==="
        echo
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

      (adminScript "unlock-all" ''
        unlock-control
        echo
        unlock-workload
      '')

      # Workload first, so Tang stays available while services shut down.
      (adminScript "lock-all" ''
        lock-workload
        echo
        lock-control
      '')

      (adminScript "server-health" ''
        echo "=== server health check ==="
        for layer in control workload; do
          echo
          echo "── $layer layer ──"
          if [ -e "/dev/mapper/$layer" ]; then
            echo "  LUKS mapper:   OPEN"
          else
            echo "  LUKS mapper:   LOCKED"
          fi
          if mountpoint -q "/mnt/$layer" 2>/dev/null; then
            df -h "/mnt/$layer" | tail -1 | awk '{print "  /mnt/'"$layer"': MOUNTED  used=" $3 " avail=" $4}'
          else
            echo "  /mnt/$layer: NOT MOUNTED"
          fi
          if systemctl is-active "$layer-online.target" >/dev/null 2>&1; then
            echo "  $layer-online.target: ACTIVE"
          else
            echo "  $layer-online.target: INACTIVE"
          fi
        done
        tang_ok=$(curl -sf --max-time 2 http://127.0.0.1:7500/adv >/dev/null 2>&1 && echo OK || echo UNREACHABLE)
        echo "  Tang: $tang_ok"
        echo
        echo "── Host root ──"
        df -h / | tail -1 | awk '{print "  /: used=" $3 " avail=" $4}'
        echo "  LVM free: $(vgs --noheadings -o vg_free --units g 2>/dev/null | tr -d ' ' || echo unknown)"
        echo
        echo "── Key services ──"
        for svc in postgresql caddy home-assistant influxdb2 grafana; do
          printf "  %-28s %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"
        done
      '')
    ];
  };
}

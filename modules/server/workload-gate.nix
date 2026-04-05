# modules/server/workload-gate.nix
#
# Workload LUKS layer gating.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT THIS MODULE DOES
# ─────────────────────────────────────────────────────────────────────────────
#
#  1. Defines a set of bind mounts that overlay /var/lib/<service> paths with
#     subdirectories from /mnt/workload. This ensures persistent state for
#     privacy-sensitive services lives on the workload LUKS layer.
#
#  2. Defines workload-online.target, which is activated after all bind mounts
#     succeed. This target is NOT started at boot.
#
#  3. Overrides privacy-sensitive services to:
#       WantedBy=workload-online.target   (not multi-user.target)
#       After=workload-online.target
#       BindsTo=workload-online.target    (stop if workload goes offline)
#
#     Services NOT in this list start normally at boot (always-on tier).
#
# ─────────────────────────────────────────────────────────────────────────────
# TWO SERVICE TIERS
# ─────────────────────────────────────────────────────────────────────────────
#
#  Always-on (host root, start at boot, no LUKS unlock needed):
#    Home Assistant, Grafana, InfluxDB, Telegraf, Mosquitto, Frigate,
#    Snapcast, Wyoming pipeline, SearXNG, Redis (Immich), Homepage
#    → data lives in /var/lib/<service> on the unencrypted host root
#    → acceptable: these are monitoring/automation services, not personal vaults
#
#  Workload-gated (start only after workload LUKS is unlocked):
#    PostgreSQL, Authentik, Nextcloud, Immich, Jellyfin, Caddy,
#    Vaultwarden, Syncthing, Samba, qBittorrent, Bitmagnet, Homepage
#    → data lives on /mnt/workload (LUKS-encrypted)
#
# ─────────────────────────────────────────────────────────────────────────────
# STUB DIRECTORIES
# ─────────────────────────────────────────────────────────────────────────────
#
#  Each /var/lib/<service> path for workload-gated services is a mode-0000 stub
#  on host root (created by secure-layers.nix tmpfiles rules). The bind mounts
#  overlay them with the actual workload data. If workload is locked, the stubs
#  are inaccessible (mode 0000) and services cannot write data to host root.
#
#  Always-on services manage their own /var/lib/<service> directories normally
#  (NixOS creates them with correct ownership and permissions at activation).
#
# ─────────────────────────────────────────────────────────────────────────────
# WORKLOAD DIRECTORY LAYOUT
# ─────────────────────────────────────────────────────────────────────────────
#
#  /mnt/workload/
#    nextcloud/      — Nextcloud home (config, data, apps)
#    immich/         — Immich thumbnails, encoded-video, profile, model-cache, DB
#    jellyfin/       — Jellyfin metadata and configuration
#    caddy/          — Caddy TLS certificates and state
#    vaultwarden/    — Vaultwarden vault database and attachments
#    syncthing/      — Syncthing configuration and index
#    qbittorrent/    — qBittorrent configuration and session state
#    bitmagnet/      — Bitmagnet torrent index
#    samba/          — Samba configuration and state
#
#  Host root (unencrypted, always available):
#    /var/lib/postgresql  — PostgreSQL data directory
#    /var/lib/authentik   — Authentik media, certs, custom templates
#    /var/lib/hass        — Home Assistant configuration and history
#    /var/lib/grafana     — Grafana dashboards and configuration
#    /var/lib/influxdb2   — InfluxDB2 time-series data
#    /var/lib/mosquitto   — Mosquitto broker state
#    /var/lib/frigate     — Frigate event database and clips
#    /var/lib/containers  — Podman container image storage
#
{ config, lib, pkgs, ... }:

let
  # ── Bind mount helper ───────────────────────────────────────────────────────
  # Creates a noauto bind mount from /mnt/workload/<subdir> to <mountPoint>.
  # The mount requires /mnt/workload to be active first.
  # "noauto"  → not in local-fs.target; not mounted at boot.
  # No "nofail" → if workload is not mounted, this unit FAILS (correct — it
  #               should fail so workload-online.target also fails, which
  #               prevents services from starting against unmounted stubs).
  mkWorkloadBind = subdir: {
    device  = "/mnt/workload/${subdir}";
    fsType  = "none";
    options = [
      "bind"
      "noauto"
      "x-systemd.requires=mnt-workload.mount"
      "x-systemd.after=mnt-workload.mount"
    ];
  };

  # ── Mount unit name helper ──────────────────────────────────────────────────
  # /var/lib/postgresql → var-lib-postgresql.mount
  mountUnit = path:
    "${lib.replaceStrings ["/"] ["-"] (lib.removePrefix "/" path)}.mount";

  # ── List of (mountPath, workloadSubdir) pairs ───────────────────────────────
  bindMounts = {
    # Workload-gated services: state lives on LUKS-encrypted /mnt/workload.
    "/var/lib/nextcloud"   = "nextcloud";
    "/var/lib/immich"      = "immich";
    "/var/lib/jellyfin"    = "jellyfin";
    "/var/lib/vaultwarden" = "vaultwarden";
    "/var/lib/syncthing"   = "syncthing";
    "/var/lib/qbittorrent" = "qbittorrent";
    "/var/lib/bitmagnet"   = "bitmagnet";
    "/var/lib/samba"       = "samba";
    # NOT included (always-on tier, host root):
    #   caddy, postgresql, authentik, grafana, influxdb2, hass, mosquitto, frigate, containers
  };

  # Unit names for all bind mounts (used in workload-online.target deps).
  bindMountUnits = map mountUnit (lib.attrNames bindMounts);

  # ── Service gate helper ─────────────────────────────────────────────────────
  # Overrides a systemd service to only run under workload-online.target.
  # wantedBy (mkForce)  — removes multi-user.target, adds workload-online.target
  # after    (mkAfter)  — service starts after workload-online is active
  # bindsTo             — service stops if workload-online.target stops
  gateService = _name: {
    wantedBy = lib.mkForce [ "workload-online.target" ];
    after    = lib.mkAfter  [ "workload-online.target" ];
    bindsTo  = [ "workload-online.target" ];
  };

  # Names of all systemd services that must be gated on workload.
  # NixOS-native services use their exact systemd unit name (no .service suffix here).
  # OCI containers use "podman-<container-name>".
  #
  # NOT listed here (always-on tier, start at boot without unlock):
  #   caddy, postgresql, authentik, home-assistant, grafana, influxdb2,
  #   mosquitto, frigate, snapserver, wyoming-*, searxng, telegraf,
  #   redis-immich, homepage
  gatedServices = [
    # ── NixOS-native services ──
    "jellyfin"
    "vaultwarden"
    "syncthing"
    "nextcloud"
    "samba-smbd"
    "samba-nmbd"
    "avahi-daemon"          # mDNS — depends on samba being up

    # ── OCI containers (podman-<name>) ──
    "podman-immich-postgres"
    "podman-immich-server"
    "podman-immich-machine-learning"
    "podman-qbittorrent"
    "podman-bitmagnet"
  ];

in
{
  # ── Workload directory initialisation ────────────────────────────────────
  # Runs after /mnt/workload is mounted, before bind mounts activate.
  # Creates any missing subdirectories and sets service-specific ownership
  # that the workload filesystem won't have on first use.
  systemd.services."workload-init" = {
    description = "Initialize workload directory structure";
    after    = [ "mnt-workload.mount" ];
    requires = [ "mnt-workload.mount" ];
    before   = bindMountUnits;
    wantedBy = [ "workload-online.target" ];
    partOf   = [ "workload-online.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "workload-init" ''
        set -euo pipefail
        W=/mnt/workload

        # Ensure each bind-mount source directory exists.
        for d in nextcloud immich jellyfin vaultwarden syncthing \
                  qbittorrent bitmagnet samba; do
          mkdir -p "$W/$d"
        done

        # Samba: winbindd requires private/ to exist before it starts.
        mkdir -p "$W/samba/private" "$W/samba/usershares"

        # Nextcloud: setup script checks that the dir is owned by 'nextcloud'.
        chown nextcloud:nextcloud "$W/nextcloud"
      '';
    };
  };

  # ── Workload bind mounts ──────────────────────────────────────────────────
  fileSystems = lib.mapAttrs (_path: subdir: mkWorkloadBind subdir) bindMounts;

  # ── workload-online.target ────────────────────────────────────────────────
  # Activated after the workload LUKS layer is mounted and all bind mounts
  # covering /var/lib/* are active. Starting this target brings all services up.
  # This target is NOT started at boot — it is started by unlock-workload.
  systemd.targets."workload-online" = {
    description = "Workload LUKS layer mounted and all service data available";
    # Require every bind mount to succeed before this target activates.
    requires = [ "mnt-workload.mount" ] ++ bindMountUnits;
    after    = [ "mnt-workload.mount" ] ++ bindMountUnits;
    # wantedBy intentionally omitted — not started at boot.
  };

  # ── Gate all application services ────────────────────────────────────────
  # Each service is moved out of multi-user.target and into workload-online.target.
  systemd.services = lib.genAttrs gatedServices gateService;

  # ── Admin scripts ─────────────────────────────────────────────────────────
  environment.systemPackages = let
    adminScript = name: body: pkgs.writeShellScriptBin name ''
      set -euo pipefail
      ${body}
    '';
  in [

    # unlock-workload: open workload LUKS, activate bind mounts, start services.
    (adminScript "unlock-workload" ''
      WORKLOAD_UUID="${config.lanbat.serverWorkloadLuksUuid}"
      echo "=== unlock-workload: opening workload LUKS layer ==="
      echo
      if [ -e /dev/mapper/workload ]; then
        echo "INFO: /dev/mapper/workload already exists, skipping luksOpen."
      else
        cryptsetup luksOpen /dev/disk/by-uuid/"$WORKLOAD_UUID" workload
      fi
      echo "Mounting /mnt/workload and activating workload-online.target..."
      systemctl start workload-online.target
      echo
      echo "Workload service status (brief):"
      systemctl list-units --state=active --type=service \
        --no-pager --no-legend 2>/dev/null | grep -E '(postgres|redis|caddy|grafana)' \
        | head -20 || true
      echo
      echo "Workload is online."
    '')

    # lock-workload: gracefully stop all services, unmount, close LUKS.
    (adminScript "lock-workload" ''
      echo "=== lock-workload: stopping workload services and locking layer ==="
      echo
      echo "This will stop ALL application services (containers, databases, etc.)."
      echo "Ensure users are warned and no critical jobs are running."
      read -r -p "Continue? [y/N] " confirm
      [[ "$confirm" == [yY] ]] || { echo "Aborted."; exit 1; }
      echo "Stopping workload-online.target (propagates to all bound services)..."
      systemctl stop workload-online.target 2>/dev/null || true
      # Allow up to 30 seconds for services to stop cleanly.
      echo "Waiting for services to stop..."
      sleep 5
      # Unmount bind mounts (in reverse dependency order).
      for mount in ${lib.concatStringsSep " " (map mountUnit (lib.attrNames bindMounts))}; do
        if mountpoint -q "$(systemctl show -p Where --value "$mount" 2>/dev/null)" 2>/dev/null; then
          systemctl stop "$mount" 2>/dev/null || umount "$(systemctl show -p Where --value "$mount")" 2>/dev/null || true
        fi
      done
      if mountpoint -q /mnt/workload; then
        umount /mnt/workload
      fi
      if [ -e /dev/mapper/workload ]; then
        cryptsetup luksClose workload
        echo "Workload LUKS closed."
      else
        echo "INFO: /dev/mapper/workload not found, already closed."
      fi
    '')

    # unlock-all: convenience wrapper — unlock control then workload.
    (adminScript "unlock-all" ''
      echo "=== unlock-all: unlocking both LUKS layers ==="
      echo
      unlock-control
      echo
      unlock-workload
    '')

    # lock-all: convenience wrapper — lock workload then control.
    # Workload must be locked first so Tang stays available during shutdown.
    (adminScript "lock-all" ''
      echo "=== lock-all: locking both LUKS layers ==="
      echo
      lock-workload
      echo
      lock-control
    '')

    # server-health: show current state of both layers and key services.
    (adminScript "server-health" ''
      echo "=== server health check ==="
      echo
      echo "── Control layer ──────────────────────────────────────"
      if [ -e /dev/mapper/control ]; then
        echo "  LUKS mapper:  OPEN  (/dev/mapper/control)"
      else
        echo "  LUKS mapper:  LOCKED"
      fi
      if mountpoint -q /mnt/control 2>/dev/null; then
        echo "  /mnt/control: MOUNTED"
      else
        echo "  /mnt/control: NOT MOUNTED"
      fi
      if mountpoint -q /var/lib/tang 2>/dev/null; then
        echo "  /var/lib/tang: MOUNTED (bind)"
      else
        echo "  /var/lib/tang: NOT MOUNTED"
      fi
      tang_ok=$(curl -sf --max-time 2 http://127.0.0.1:7500/adv >/dev/null 2>&1 && echo OK || echo UNREACHABLE)
      echo "  Tang:         $tang_ok"
      echo
      echo "── Workload layer ─────────────────────────────────────"
      if [ -e /dev/mapper/workload ]; then
        echo "  LUKS mapper:  OPEN  (/dev/mapper/workload)"
      else
        echo "  LUKS mapper:  LOCKED"
      fi
      if mountpoint -q /mnt/workload 2>/dev/null; then
        df -h /mnt/workload | tail -1 | awk '{print "  /mnt/workload: MOUNTED  used=" $3 " avail=" $4}'
      else
        echo "  /mnt/workload: NOT MOUNTED"
      fi
      if systemctl is-active workload-online.target >/dev/null 2>&1; then
        echo "  workload-online.target: ACTIVE"
      else
        echo "  workload-online.target: INACTIVE"
      fi
      echo
      echo "── Key services ───────────────────────────────────────"
      for svc in postgresql caddy home-assistant influxdb2 grafana; do
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        printf "  %-28s %s\n" "$svc" "$state"
      done
    '')

  ];
}

# modules/common/auto-upgrade.nix
#
# Unattended NixOS upgrades from a locally-cloned configuration repo.
#
# Design
# ------
# NixOS's built-in `system.autoUpgrade` runs `nixos-rebuild switch` on a
# schedule.  We configure it to use the local clone of this repo at
# /etc/nixos rather than a remote flake URL, for two reasons:
#
#   1. `--impure` is required to read local.nix from disk.  A remote flake
#      (github:user/repo) is fetched into the Nix store, so ./local.nix
#      would be looked up inside the store (where it doesn't exist).
#      A local path (/etc/nixos) allows --impure to find local.nix correctly.
#
#   2. We can control exactly which commit is built by pulling git first.
#
# Before nixos-upgrade.service runs, a companion service pulls the latest
# changes from git.  If git pull fails (no network, auth error, merge
# conflict), the upgrade continues from the currently-checked-out state —
# which is always safe.
#
# Server vs Pi
# ------------
# The server CANNOT auto-reboot — it requires a manual LUKS passphrase at
# boot.  Set `system.autoUpgrade.allowReboot = false` (the default) on the
# server.  Upgrades apply at the next manual reboot.
#
# The Pi CAN auto-reboot cleanly — Clevis/Tang handles LUKS unlock
# automatically as long as the server is up.  Set `allowReboot = true` on
# the Pi with a sensible `rebootWindow`.
#
# Setup
# -----
# 1. Clone the repo on each machine:
#      git clone <your-repo-url> /etc/nixos
# 2. Configure a git remote so pull works (HTTPS token or SSH deploy key).
#    See docs/deployment-checklist.md § "Clone config repo on each machine".
# 3. Each host configures system.autoUpgrade in its own default.nix.
#
{ config, pkgs, lib, ... }:

{
  # Pull the latest config from git before each upgrade attempt.
  systemd.services.nixos-upgrade-pull = {
    description = "Pull latest NixOS configuration from git";

    # Run before the upgrade, as part of the same activation.
    before   = [ "nixos-upgrade.service" ];
    wantedBy = [ "nixos-upgrade.service" ];

    # Skip silently if /etc/nixos is not a git repo.
    unitConfig.ConditionPathExists = "/etc/nixos/.git";

    path = [ pkgs.git pkgs.openssh ];

    serviceConfig = {
      Type            = "oneshot";
      User            = "root";
      WorkingDirectory = "/etc/nixos";
      ExecStart = pkgs.writeShellScript "nixos-upgrade-pull" ''
        set -euo pipefail

        # Fetch from remote. Fail gracefully — the upgrade will proceed
        # using the current local checkout if this step fails.
        if ! git fetch origin; then
          echo "WARNING: git fetch failed. Upgrading from current local checkout."
          exit 0
        fi

        # Fast-forward only — never auto-merge diverged histories.
        if ! git merge --ff-only origin/main; then
          echo "WARNING: git merge failed (not fast-forward?). Upgrading from current local checkout."
          exit 0
        fi

        echo "Config repo updated to $(git rev-parse --short HEAD)."
      '';
    };
  };
}

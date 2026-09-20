# modules/core/auto-upgrade.nix
#
# Unattended NixOS upgrades from a locally-cloned configuration repo.
#
# Design
# ------
# NixOS's built-in `system.autoUpgrade` runs `nixos-rebuild switch` on a
# schedule.  We point it at the local clone of this repo with a path: flake
# reference ("path:/etc/nixos#<host>") rather than a remote flake URL, for
# two reasons:
#
#   1. deploy.nix and deployments/*/deploy.nix are gitignored.  Remote flakes
#      and git-based references only include tracked files, so they would
#      build with placeholder settings.  A path: reference copies the
#      directory as it is, including those files.
#
#   2. We can control exactly which commit is built by pulling git first.
#
# The flake reference and schedule are set below for every host; each role
# only toggles `enable` and the reboot behaviour.  `machineName` mirrors
# `hostFlakeName` in lib/default.nix so the #<attr> matches the
# nixosConfigurations key.
#
# `nixos-rebuild --upgrade` is a no-op for flake-based systems, so a host
# never bumps nixpkgs on its own.  Inputs change only when `nix flake update`
# and a push happen on the workstation, which the hosts then pull.
#
# Before nixos-upgrade.service runs, the companion nixos-upgrade-pull service
# pulls the latest changes from git.  If the pull fails (no network, auth
# error, merge conflict), the upgrade continues from the currently-checked-out
# state — which is always safe.
#
# Server vs Pi
# ------------
# The server CANNOT auto-reboot — it requires manual LUKS unlock at boot.  Its
# role keeps `allowReboot = false` (the default), so upgrades apply but take
# effect at the next manual reboot.
#
# The Pi CAN auto-reboot cleanly — Clevis/Tang handles LUKS unlock
# automatically as long as the server is up.  Its role sets `allowReboot =
# true` with a `rebootWindow` that contains the upgrade time (`dates`).
#
# Setup
# -----
# 1. Clone the repo on each machine and add the gitignored deploy files:
#      git clone <your-repo-url> /etc/nixos
#      cp deploy.nix /etc/nixos/deploy.nix
#      cp -r deployments/<profile> /etc/nixos/deployments/<profile>
# 2. Configure a git remote so pull works (SSH deploy key).  See
#    docs/deployment-checklist.md § "Clone config repo on each machine".
# 3. The host's role enables system.autoUpgrade (see lib/roles/).
#
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Mirrors hostFlakeName in lib/default.nix — keep the two in sync.
  machineName =
    if config.lanbat.profile == "default" then
      config.lanbat.hostKey
    else
      "${config.lanbat.profile}-${config.lanbat.hostKey}";
in
{
  # Build the locally-checked-out config for this host on a nightly schedule.
  system.autoUpgrade = {
    flake = lib.mkDefault "path:/etc/nixos#${machineName}";
    # 04:40 falls inside the Pi reboot window (04:00–06:00) set by the Pi roles.
    dates = lib.mkDefault "04:40";
  };

  # Pull the latest config from git before each upgrade attempt.
  systemd.services.nixos-upgrade-pull = {
    description = "Pull latest NixOS configuration from git";

    # Run before the upgrade, as part of the same activation.
    before = [ "nixos-upgrade.service" ];
    wantedBy = [ "nixos-upgrade.service" ];

    # Skip silently if /etc/nixos is not a git repo.
    unitConfig.ConditionPathExists = "/etc/nixos/.git";

    path = [
      pkgs.git
      pkgs.openssh
    ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      WorkingDirectory = "/etc/nixos";
      ExecStart = pkgs.writeShellScript "nixos-upgrade-pull" ''
        set -euo pipefail

        # Fetch from remote. Fail gracefully — the upgrade will proceed
        # using the current local checkout if this step fails.
        if ! git fetch origin; then
          echo "WARNING: git fetch failed. Upgrading from current local checkout."
          exit 0
        fi

        # Fast-forward the checked-out branch to its upstream; never auto-merge diverged histories.
        if ! git merge --ff-only '@{u}'; then
          echo "WARNING: git merge failed (not fast-forward, or no upstream branch). Upgrading from current local checkout."
          exit 0
        fi

        echo "Config repo updated to $(git rev-parse --short HEAD)."
      '';
    };
  };
}

# modules/core/gc.nix
#
# Nix garbage collection, on every host.
#
# Collection is enabled by default: a homelab that never collects fills its
# root filesystem and then fails to build, which on this design also means it
# cannot roll back. A deployment that keeps every generation on purpose — a
# build host, or a machine whose store lives on its own large volume — turns it
# off with lanbat.gc.enable = false.
#
# Two mechanisms are configured here and they are independent:
#
#   * the scheduled collection (lanbat.gc.enable), which runs on a timer and
#     deletes generations older than lanbat.gc.options; and
#   * the during-build safety valve (minFree/maxFree), which collects mid-build
#     when free space runs low so a build fails to finish rather than filling
#     the disk. This stays on when enable = false, because it protects builds
#     rather than reclaiming old generations. Set minFree = 0 to disable it.
{
  config,
  lib,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.lanbat.gc;
in
{
  options.lanbat.gc = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Collect garbage on a timer, deleting generations older than
        lanbat.gc.options. Disabling this keeps every generation until
        something collects by hand (nix-collect-garbage).
      '';
    };

    dates = mkOption {
      type = types.str;
      default = "weekly";
      example = "daily";
      description = "When the scheduled collection runs, in systemd calendar format.";
    };

    options = mkOption {
      type = types.str;
      default = "--delete-older-than 30d";
      example = "--delete-older-than 7d";
      description = ''
        Arguments passed to nix-collect-garbage by the scheduled run. The
        default keeps a month of generations, which is long enough to roll back
        to a known-good system after a bad deploy.
      '';
    };

    minFree = mkOption {
      type = types.ints.unsigned;
      default = 2 * 1024 * 1024 * 1024;
      description = ''
        Free space, in bytes, below which the daemon collects garbage during a
        build. Zero disables the during-build valve entirely. Independent of
        lanbat.gc.enable.
      '';
    };

    maxFree = mkOption {
      type = types.ints.unsigned;
      default = 10 * 1024 * 1024 * 1024;
      description = ''
        Free space, in bytes, that a during-build collection tries to reach
        before it stops. Must be at least minFree.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.maxFree >= cfg.minFree;
        message = "lanbat.gc.maxFree (${toString cfg.maxFree}) must be at least lanbat.gc.minFree (${toString cfg.minFree}).";
      }
      {
        assertion = cfg.enable -> cfg.options != "";
        message = "lanbat.gc.options is empty, so the scheduled collection would delete every generation that is not currently in use. Set it, or disable lanbat.gc.enable.";
      }
    ];

    nix = {
      gc = {
        automatic = cfg.enable;
        inherit (cfg) dates options;
      };

      settings = {
        min-free = cfg.minFree;
        max-free = cfg.maxFree;
      };
    };
  };
}

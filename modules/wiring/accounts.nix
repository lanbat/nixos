# modules/wiring/accounts.nix
#
# Creates the dedicated account of every service that declares
# lanbat.services.<name>.account: a system user and group sharing one pinned
# ID. Container accounts also get what rootless Podman needs:
#
#   linger            /run/user/<uid> exists without a login session
#   home + createHome image and container storage in ~/.local/share/containers
#   subUid/subGid     user namespace ranges, derived from the UID
#                     (uid × 65536), so they never overlap
#
# A weekly timer prunes dangling images of each container account. The
# system-wide virtualisation.podman.autoPrune only covers root's storage.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  accounts = lib.mapAttrsToList (_: svc: svc.account) (
    lib.filterAttrs (_: svc: svc.account != null) config.lanbat.services
  );
  containerAccounts = lib.filter (a: a.container) accounts;

  subIdRange = a: {
    start = a.uid * 65536;
    count = 65536;
  };
in
{
  users.groups = lib.listToAttrs (map (a: lib.nameValuePair a.name { gid = a.uid; }) accounts);

  users.users = lib.listToAttrs (
    map (
      a:
      lib.nameValuePair a.name (
        {
          uid = a.uid;
          group = a.name;
          isSystemUser = true;
          inherit (a) extraGroups;
        }
        // lib.optionalAttrs a.container {
          linger = true;
          home = "/var/lib/containers/${a.name}";
          createHome = true;
          subUidRanges = [
            {
              startUid = (subIdRange a).start;
              inherit (subIdRange a) count;
            }
          ];
          subGidRanges = [
            {
              startGid = (subIdRange a).start;
              inherit (subIdRange a) count;
            }
          ]
          ++ a.extraSubGidRanges;
        }
      )
    ) accounts
  );

  # linger-users.service runs once per container account during a switch and
  # trips the default start rate limit, showing as failed although every run
  # succeeds.
  systemd.services = lib.mkIf (containerAccounts != [ ]) (
    {
      linger-users.unitConfig.StartLimitIntervalSec = lib.mkForce 0;
    }
    // lib.listToAttrs (
      map (
        a:
        lib.nameValuePair "podman-prune-${a.name}" {
          description = "Prune dangling Podman images of ${a.name}";
          path = [ "/run/wrappers" ];
          environment.XDG_RUNTIME_DIR = "/run/user/${toString a.uid}";
          serviceConfig = {
            Type = "oneshot";
            User = a.name;
            ExecStart = "${config.virtualisation.podman.package}/bin/podman image prune --force";
          };
        }
      ) containerAccounts
    )
  );

  systemd.timers = lib.listToAttrs (
    map (
      a:
      lib.nameValuePair "podman-prune-${a.name}" {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "weekly";
          RandomizedDelaySec = "1h";
          Persistent = true;
        };
      }
    ) containerAccounts
  );
}

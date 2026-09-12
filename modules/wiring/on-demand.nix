# modules/wiring/on-demand.nix
#
# On-demand activation for services that set lanbat.services.<name>.onDemand.
#
# How it works
# ------------
# 1. A small Python HTTP server (the activator) listens on onDemand.activatorPort.
#    Caddy proxies the service's vhost to it (modules/wiring/caddy.nix).
# 2. If the real service answers on its port, the activator proxies the request.
#    Otherwise it runs `systemctl start <unit>` and returns a loading page that
#    refreshes every 5 s.
# 3. The activator writes a timestamp file on every proxied request. A timer
#    stops the unit once it has been idle for onDemand.idleMinutes.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  onDemand = lib.filterAttrs (_: svc: svc.onDemand != null) config.lanbat.services;

  activatorScript = pkgs.writeText "activator.py" (
    builtins.readFile ../../pkgs/on-demand-activator/activator.py
  );

  mkActivatorService = name: svc: {
    description = "On-demand activator for ${name}";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "root"; # needs systemctl
      ExecStart =
        "${pkgs.python3}/bin/python3 ${activatorScript} "
        + "--listen-port ${toString svc.onDemand.activatorPort} "
        + "--real-port   ${toString svc.port} "
        + "--target-svc  ${svc.onDemand.unit} "
        + "--stamp-file  /run/ondemand-${name}.stamp";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  mkIdleService = name: svc: {
    description = "Stop ${name} if idle";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "idle-stop-${name}" ''
        stamp=/run/ondemand-${name}.stamp
        if [ ! -f "$stamp" ]; then exit 0; fi
        last=$(cat "$stamp")
        now=$(date +%s)
        idle=$(( now - last ))
        limit=$(( ${toString svc.onDemand.idleMinutes} * 60 ))
        if [ "$idle" -ge "$limit" ]; then
          echo "Stopping ${name} after $idle seconds idle"
          systemctl stop ${svc.onDemand.unit} || true
          rm -f "$stamp"
        fi
      '';
    };
  };

  mkIdleTimer = name: svc: {
    description = "Idle-shutdown timer for ${name}";
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "${toString svc.onDemand.idleMinutes}min";
    };
    wantedBy = [ "timers.target" ];
  };
in
{
  systemd.services =
    lib.mapAttrs' (n: s: lib.nameValuePair "ondemand-activator-${n}" (mkActivatorService n s)) onDemand
    // lib.mapAttrs' (n: s: lib.nameValuePair "ondemand-idle-stop-${n}" (mkIdleService n s)) onDemand;

  systemd.timers = lib.mapAttrs' (
    n: s: lib.nameValuePair "ondemand-idle-stop-${n}" (mkIdleTimer n s)
  ) onDemand;
}

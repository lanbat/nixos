# modules/server/on-demand.nix
#
# On-demand service activator framework.
#
# For services like Bitmagnet that do not need to run 24/7, we run a tiny
# HTTP "activator" process in front of the real service.
#
# How it works
# ------------
# 1. A lightweight Python HTTP server (the activator) listens on a dedicated
#    port (e.g. 3332 for Bitmagnet).
# 2. Caddy reverse-proxies to the activator port for that hostname.
# 3. When Caddy hits the activator:
#      a. If the real service is already healthy, the activator transparently
#         proxies the request to the real service.
#      b. If the real service is not running, the activator:
#           - Runs `systemctl start <target-service>` (non-blocking).
#           - Returns a 200 HTML loading page with <meta refresh> every 5 s.
# 4. Once the real service is healthy, subsequent requests proxy straight
#    through with no loading page — the activator adds only one TCP hop.
# 5. A systemd timer checks every 30 minutes whether the real service has
#    received any traffic in the last 30 minutes and stops it if idle.
#    (The activator writes a timestamp file on every proxied request.)
#
# This module exposes an option to declare on-demand services:
#
#   lanbat.onDemand.services = {
#     bitmagnet = {
#       activatorPort = 3332;
#       realPort      = 3333;
#       targetService = "podman-bitmagnet.service";
#       idleMinutes   = 30;
#     };
#   };
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.lanbat.onDemand;

  activatorScript = pkgs.writeText "activator.py" (builtins.readFile ../../pkgs/on-demand-activator/activator.py);

  mkActivatorService = name: svcCfg: {
    description = "On-demand activator for ${name}";
    after    = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "simple";
      User            = "root"; # needs systemctl
      ExecStart       = "${pkgs.python3}/bin/python3 ${activatorScript} "
                        + "--listen-port ${toString svcCfg.activatorPort} "
                        + "--real-port   ${toString svcCfg.realPort} "
                        + "--target-svc  ${svcCfg.targetService} "
                        + "--stamp-file  /run/ondemand-${name}.stamp";
      Restart         = "on-failure";
      RestartSec      = "5s";
    };
  };

  mkIdleTimer = name: svcCfg: {
    description = "Idle-shutdown timer for ${name}";
    timerConfig = {
      OnBootSec   = "5min";
      OnUnitActiveSec = "${toString svcCfg.idleMinutes}min";
    };
    wantedBy = [ "timers.target" ];
  };

  mkIdleService = name: svcCfg: {
    description = "Stop ${name} if idle";
    serviceConfig = {
      Type    = "oneshot";
      ExecStart = pkgs.writeShellScript "idle-stop-${name}" ''
        stamp=/run/ondemand-${name}.stamp
        if [ ! -f "$stamp" ]; then exit 0; fi
        last=$(cat "$stamp")
        now=$(date +%s)
        idle=$(( now - last ))
        limit=$(( ${toString svcCfg.idleMinutes} * 60 ))
        if [ "$idle" -ge "$limit" ]; then
          echo "Stopping ${name} after $idle seconds idle"
          systemctl stop ${svcCfg.targetService} || true
          rm -f "$stamp"
        fi
      '';
    };
  };
in
{
  options.lanbat.onDemand = {
    services = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          activatorPort = mkOption { type = types.port; };
          realPort      = mkOption { type = types.port; };
          targetService = mkOption { type = types.str; };
          idleMinutes   = mkOption { type = types.int; default = 30; };
        };
      });
      default = {};
    };
  };

  config = mkIf (cfg.services != {}) {
    systemd.services =
      (mapAttrs' (n: s: nameValuePair "ondemand-activator-${n}" (mkActivatorService n s)) cfg.services)
      //
      (mapAttrs' (n: s: nameValuePair "ondemand-idle-stop-${n}" (mkIdleService n s)) cfg.services);

    systemd.timers =
      mapAttrs' (n: s: nameValuePair "ondemand-idle-stop-${n}" (mkIdleTimer n s)) cfg.services;
  };
}

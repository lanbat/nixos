# services/telegraf.nix
#
# Telegraf metrics agent — server side.
#
# Telegraf collects system and service metrics and writes them to InfluxDB.
# Grafana queries InfluxDB to display dashboards and fire alerts.
#
# Collected metrics
# -----------------
# System:
#   cpu          — per-core and total CPU usage
#   mem          — RAM and swap usage
#   disk         — filesystem usage per mount point
#   diskio       — read/write throughput per device
#   net          — network interface bytes/packets/errors
#   system       — load average, uptime, number of processes
#   processes    — process states (running, sleeping, zombie, etc.)
#   temp         — hardware temperature sensors (if available)
#
# Services:
#   systemd_units — active/failed state for all systemd services
#   nfsclient     — NFS mount operation counters and latency
#   http_response — HTTP health checks for Grafana, Home Assistant, Jellyfin,
#                   Immich, and Vaultwarden (localhost endpoints)
#   ping          — reachability of the Pi, default gateway, and 1.1.1.1
#   redis         — shared Redis instance (127.0.0.1:6379, no auth)
#
# Note: inputs.docker removed — rootless Podman containers each have their own
# socket under /run/user/<uid>/podman; there is no single shared Docker-compat
# socket for telegraf to query.  Container metrics can be added via cgroups or
# per-container prometheus exporters if needed later.
#
# Secrets
# -------
# telegraf-token.age — one line: TELEGRAF_INFLUXDB_TOKEN=<write token>
# Any random value (openssl rand -base64 48). services/influxdb.nix provisions
# it in InfluxDB as a write token for the "metrics" bucket; the Pi's Telegraf
# uses the same token.
#
# Always-on: yes. No NFS dependency.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  lanbat = config.lanbat;

  serviceHealthCheck = name: port: path:
    {
      urls = [ "http://127.0.0.1:${toString port}${path}" ];
      response_status_code = 200;
      interval = "60s";
      response_timeout = "5s";
      name_override = name;
    };
in

{
  services.telegraf = {
    enable = true;

    extraConfig = lib.mkForce {
      agent = {
        interval = "30s";
        flush_interval = "30s";
        round_interval = true;
        metric_batch_size = 1000;
        metric_buffer_limit = 10000;
        collection_jitter = "5s";
        flush_jitter = "5s";
        precision = "0s";
      };

      outputs.influxdb_v2 = [
        {
          urls = [ "http://127.0.0.1:8086" ];
          token = "$TELEGRAF_INFLUXDB_TOKEN";
          organization = "homelab";
          bucket = "metrics";
        }
      ];

      inputs.cpu = [
        {
          percpu = true;
          totalcpu = true;
          collect_cpu_time = false;
          report_active = false;
        }
      ];
      inputs.mem = [ { } ];
      inputs.disk = [
        {
          ignore_fs = [
            "tmpfs"
            "devtmpfs"
            "devfs"
            "iso9660"
            "overlay"
            "aufs"
            "squashfs"
            "nsfs"
          ];
        }
      ];
      inputs.diskio = [ { } ];
      inputs.net = [ { ignore_protocol_stats = true; } ];
      inputs.system = [ { } ];
      inputs.processes = [ { } ];
      inputs.temp = [ { } ];
      inputs.systemd_units = [ { } ];
      inputs.nfsclient = [ { fullstat = false; } ];

      inputs.http_response = [
        (serviceHealthCheck "grafana" lanbat.services.grafana.port "/api/health")
        (serviceHealthCheck "home-assistant" lanbat.services.home-assistant.port "/")
        (serviceHealthCheck "jellyfin" lanbat.services.jellyfin.port "/health")
        (serviceHealthCheck "immich" lanbat.services.immich.port "/api/server/ping")
        (serviceHealthCheck "vaultwarden" lanbat.services.vaultwarden.port "/alive")
      ];

      inputs.ping = [
        {
          urls = [
            lanbat.piIp
            lanbat.gatewayIp
            "1.1.1.1"
          ];
        }
      ];

      inputs.redis = [
        {
          servers = [ "tcp://127.0.0.1:6379" ];
        }
      ];
    };
  };

  systemd.services.telegraf.serviceConfig = {
    AmbientCapabilities = "CAP_NET_RAW";
    EnvironmentFile = [
      config.age.secrets.telegraf-token.path
    ];
  };

  lanbat.services.telegraf.secrets.telegraf-token = { };
}

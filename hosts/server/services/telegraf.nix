# hosts/server/services/telegraf.nix
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
#
# Note: inputs.docker removed — rootless Podman containers each have their own
# socket under /run/user/<uid>/podman; there is no single shared Docker-compat
# socket for telegraf to query.  Container metrics can be added via cgroups or
# per-container prometheus exporters if needed later.
#
# Secrets
# -------
# telegraf-token.age — one line: TELEGRAF_INFLUXDB_TOKEN=<write token>
# Create the token in InfluxDB UI after first deploy:
#   Data → API Tokens → Generate API Token → Write to "metrics" bucket
# Then store it: cd secrets && agenix -e telegraf-token.age
#
# Always-on: yes. No NFS dependency.
{ config, pkgs, lib, ... }:

{
  services.telegraf = {
    enable = true;

    extraConfig = lib.mkForce {
      agent = {
        interval            = "30s";
        flush_interval      = "30s";
        round_interval      = true;
        metric_batch_size   = 1000;
        metric_buffer_limit = 10000;
        collection_jitter   = "5s";
        flush_jitter        = "5s";
        precision           = "0s";
      };

      outputs.influxdb_v2 = [{
        urls         = [ "http://127.0.0.1:8086" ];
        token        = "$TELEGRAF_INFLUXDB_TOKEN";
        organization = "homelab";
        bucket       = "metrics";
      }];

      inputs.cpu = [{
        percpu          = true;
        totalcpu        = true;
        collect_cpu_time = false;
        report_active   = false;
      }];
      inputs.mem        = [{}];
      inputs.disk       = [{
        ignore_fs = [ "tmpfs" "devtmpfs" "devfs" "iso9660" "overlay" "aufs" "squashfs" "nsfs" ];
      }];
      inputs.diskio     = [{}];
      inputs.net        = [{ ignore_protocol_stats = true; }];
      inputs.system     = [{}];
      inputs.processes  = [{}];
      inputs.temp       = [{}];
      inputs.systemd_units = [{}];
      inputs.nfsclient  = [{ fullstat = false; }];
    };
  };

  # Inject the InfluxDB write token at runtime — never stored in Nix store.
  systemd.services.telegraf.serviceConfig.EnvironmentFile = [
    config.age.secrets.telegraf-token.path
  ];

  # Agenix secret
  age.secrets.telegraf-token = {
    file  = ../../../secrets/telegraf-token.age;
    owner = "telegraf";
  };
}

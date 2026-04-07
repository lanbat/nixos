# hosts/pi/services/telegraf.nix
#
# Telegraf metrics agent — Pi side.
#
# Collects Pi system metrics and writes them to InfluxDB on the server.
# InfluxDB listens on the server's LAN IP (port 8086) and is firewall-
# restricted to the Pi's IP only (see hosts/server/services/influxdb.nix).
#
# Collected metrics
# -----------------
#   cpu          — CPU usage
#   mem          — RAM and swap
#   disk         — filesystem usage including NFS-exported drives
#   diskio       — drive read/write throughput
#   net          — network interface stats
#   system       — load average, uptime
#   processes    — process states
#   temp         — Raspberry Pi CPU temperature (via thermal zone)
#
# Secrets
# -------
# Shares telegraf-token.age with the server — same write token, separate
# agenix declaration in hosts/pi/default.nix.
#
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
        urls         = [ "http://${config.lanbat.serverIp}:8086" ];
        token        = "$TELEGRAF_INFLUXDB_TOKEN";
        organization = "homelab";
        bucket       = "metrics";
      }];

      inputs.cpu = [{
        percpu           = true;
        totalcpu         = true;
        collect_cpu_time = false;
        report_active    = false;
      }];
      inputs.mem     = [{}];
      inputs.disk    = [{
        # Include the LUKS-mounted drives to track fill levels.
        mount_points = [ "/" "/mnt/storage-a" "/mnt/storage-b" ];
        ignore_fs    = [ "tmpfs" "devtmpfs" "devfs" "iso9660" "overlay" "aufs" "squashfs" "nsfs" ];
      }];
      inputs.diskio    = [{}];
      inputs.net       = [{ ignore_protocol_stats = true; }];
      inputs.system    = [{}];
      inputs.processes = [{}];
      # Raspberry Pi CPU temperature via kernel thermal zone.
      inputs.temp      = [{}];
    };
  };

  # Inject the InfluxDB write token at runtime.
  systemd.services.telegraf.serviceConfig.EnvironmentFile = [
    config.age.secrets.telegraf-token.path
  ];

  # Agenix secret
  age.secrets.telegraf-token = {
    file  = ../../../secrets/telegraf-token.age;
    owner = "telegraf";
  };
}

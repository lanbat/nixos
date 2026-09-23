# modules/pi/telegraf.nix
#
# Telegraf metrics agent — Pi side.
#
# Collects Pi system metrics and writes them to InfluxDB on the server.
# InfluxDB listens on the server's LAN IP (port 8086) and is firewall-
# restricted to the Pi's IP only (see services/influxdb.nix).
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
#   ping         — reachability of the server
#   smart        — S.M.A.R.T. attributes for the NVMe drives backing
#                  /mnt/storage-<drive> (hosts.<key>.storage.drives)
#
# Secrets
# -------
# Shares telegraf-token.age with the server: the same write token, so the Pi's
# host key must be a recipient of that file.
#
{
  config,
  pkgs,
  lib,
  ...
}:

let
  lanbat = config.lanbat;
  # Empty on a voice Pi, which has no storage drives.
  storageDrives = lanbat.hosts.${lanbat.hostKey}.storage.drives or { };
  driveNames = lib.attrNames storageDrives;
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
          urls = [ "http://${config.lanbat.deployment.serverIp}:8086" ];
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
          # Include the LUKS-mounted drives to track fill levels.
          mount_points = [ "/" ] ++ map (drive: "/mnt/storage-${drive}") driveNames;
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
      # Raspberry Pi CPU temperature via kernel thermal zone.
      inputs.temp = [ { } ];

      inputs.ping = [
        {
          urls = [ lanbat.deployment.serverIp ];
        }
      ];

      # NVMe SMART via smartctl/nvme-cli. telegraf is in the disk group so
      # use_sudo is not required.
      inputs.smart = [
        {
          use_sudo = false;
          path_smartctl = "${pkgs.smartmontools}/bin/smartctl";
          path_nvme = "${pkgs.nvme-cli}/bin/nvme";
          devices = map (drive: "/dev/disk/by-id/${storageDrives.${drive}}") driveNames;
        }
      ];
    };
  };

  systemd.services.telegraf.serviceConfig = {
    AmbientCapabilities = "CAP_NET_RAW";
    SupplementaryGroups = [ "disk" ];
    EnvironmentFile = [
      config.age.secrets.telegraf-token.path
    ];
  };

  lanbat.services.telegraf.secrets.telegraf-token = { };
  lanbat.services.telegraf.consumes = [ "influxdb" ];
}

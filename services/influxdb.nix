# services/influxdb.nix
#
# InfluxDB 2 — time-series database for metrics and monitoring.
#
# Design
# ------
# - NixOS-native service; no container needed.
# - Binds on all interfaces (0.0.0.0:8086) so the Pi can write metrics; the
#   firewall below restricts access to loopback and the Pi's IP only. Not
#   exposed through Caddy — Grafana and Telegraf on the server use
#   http://localhost:8086 (not 127.0.0.1 — that can hang behind the rule).
# - Initial org/bucket/admin are provisioned declaratively via the NixOS
#   module's provision option.  After first boot this block is a no-op.
# - The operator token is loaded from an agenix secret so it is never in
#   the Nix store.  Grafana reads the same token value from its own env file.
#
# Secrets
# -------
# influxdb-admin-password.age — single line, the initial admin password.
# influxdb-admin-token.age    — single line, the operator API token.
#   Generate with: openssl rand -base64 48
#   This value must also be present in grafana-env.age as INFLUXDB_TOKEN=...
#
# State
# -----
# /var/lib/influxdb2  — managed by the module (back this up!)
#
# Always-on: yes.  No NFS dependency.
{ config, ... }:

{
  services.influxdb2 = {
    enable = true;

    settings = {
      # Bind on all interfaces so the Pi's Telegraf agent can write metrics.
      # Access is restricted to localhost and the Pi's IP via the firewall rule
      # below — InfluxDB has no built-in IP allowlist.
      http-bind-address = "0.0.0.0:8086";
    };

    provision = {
      enable = true;

      initialSetup = {
        organization = "homelab";
        bucket = "metrics";
        username = "admin";
        # Plaintext password file (one line).
        passwordFile = config.age.secrets.influxdb-admin-password.path;
        # Operator token — used by Grafana as the datasource credential.
        tokenFile = config.age.secrets.influxdb-admin-token.path;
        # Infinite retention — prune old data manually or per-bucket as needed.
        retention = 0;
      };
      organizations.homelab = {
        buckets.metrics.retention = 0;
        # The write token Telegraf uses on the server and the Pi, with the
        # value from telegraf-token.age (see influxdb2-telegraf-token below).
        auths.telegraf = {
          description = "Telegraf on the server and the Pi";
          tokenFile = "/run/influxdb2-telegraf-token/token";
          writeBuckets = [ "metrics" ];
        };
      };
    };
  };

  # telegraf-token.age holds TELEGRAF_INFLUXDB_TOKEN=<token> for Telegraf's
  # environment; provisioning wants the bare token. The module reads it in
  # influxdb2's preStart, which runs as the influxdb2 user, so the directory
  # and file belong to its group.
  systemd.services.influxdb2-telegraf-token = {
    description = "Bare Telegraf write token for InfluxDB provisioning";
    before = [ "influxdb2.service" ];
    requiredBy = [ "influxdb2.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Group = "influxdb2";
      RuntimeDirectory = "influxdb2-telegraf-token";
      RuntimeDirectoryMode = "0750";
      UMask = "0027";
    };
    script = ''
      sed -n 's/^TELEGRAF_INFLUXDB_TOKEN=//p' ${config.age.secrets.telegraf-token.path} \
        > /run/influxdb2-telegraf-token/token
      test -s /run/influxdb2-telegraf-token/token
    '';
  };

  lanbat.services.influxdb = {
    extraPorts = [ 8086 ];
    secrets = {
      influxdb-admin-password.owner = "influxdb2";
      influxdb-admin-token.owner = "influxdb2";
    };
  };

  # The Pi's Telegraf writes metrics here; nobody else on the LAN may connect.
  # Not loopback: the server's own Telegraf and Grafana connect over it, and
  # without ! -i lo the rule dropped them too.
  networking.firewall = {
    allowedTCPPorts = [ 8086 ];
    extraCommands = ''
      iptables -I INPUT -p tcp --dport 8086 ! -i lo ! -s ${config.lanbat.piIp} -j DROP
    '';
  };
}

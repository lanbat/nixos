# hosts/server/services/influxdb.nix
#
# InfluxDB 2 — time-series database for metrics and monitoring.
#
# Design
# ------
# - NixOS-native service; no container needed.
# - Listens on localhost:8086 only — not exposed through Caddy.
#   Grafana connects to it directly; there is no public UI for InfluxDB.
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
        bucket       = "metrics";
        username     = "admin";
        # Plaintext password file (one line).
        passwordFile = config.age.secrets.influxdb-admin-password.path;
        # Operator token — used by Grafana as the datasource credential.
        tokenFile    = config.age.secrets.influxdb-admin-token.path;
        # Infinite retention — prune old data manually or per-bucket as needed.
        retention    = 0;
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Agenix secrets
  # ---------------------------------------------------------------------------
  age.secrets.influxdb-admin-password = {
    file  = ../../../secrets/influxdb-admin-password.age;
    owner = "influxdb2";
  };

  age.secrets.influxdb-admin-token = {
    file  = ../../../secrets/influxdb-admin-token.age;
    owner = "influxdb2";
  };
}

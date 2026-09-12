# services/bitmagnet.nix
#
# Bitmagnet — DHT crawler and torrent search engine.
#
# On-demand: yes.
#   Bitmagnet is resource-intensive (crawls DHT constantly when running).
#   It runs on-demand via the activator pattern (see modules/wiring/on-demand.nix).
#   Caddy routes to the activator; the activator starts Bitmagnet on first
#   request and proxies transparently once it is healthy.
#   After 30 minutes idle, a systemd timer stops it.
#
# Storage:
#   /var/lib/bitmagnet/   — config, data (server-local)
#   PostgreSQL database   — shared instance, "bitmagnet" db
#
# No NFS dependency.
{
  config,
  pkgs,
  lib,
  ...
}:

{
  lanbat.services.bitmagnet = {
    subdomain = "bitmagnet";
    port = 3333;
    auth = "forward-auth";
    tier = "workload";
    state = [ "bitmagnet" ];
    units = [ "podman-bitmagnet" ];
    # Mounted as /root/.config/bitmagnet; container root maps to host bitmagnet.
    workloadDirs."bitmagnet".user = "bitmagnet";
    onDemand = {
      activatorPort = 3332;
      idleMinutes = 4320; # 3 days: DHT crawling needs sustained uptime to build its index
    };
    account = {
      uid = 963;
      container = true;
    };
    # group postgres: postgresql-bitmagnet-init reads the password too.
    secrets.bitmagnet-db-pass = {
      group = "postgres";
      mode = "0440";
    };
    dashboard = {
      group = "Downloads";
      name = "Bitmagnet";
      description = "DHT crawler & search (on-demand)";
    };
  };

  lanbat.postgresql.databases.bitmagnet = {
    instance = "workload";
    passwordFile = config.age.secrets.bitmagnet-db-pass.path;
  };

  # ---------------------------------------------------------------------------
  # Bitmagnet container
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers.containers."bitmagnet" = {
    image = "ghcr.io/bitmagnet-io/bitmagnet:latest";
    cmd = [
      "worker"
      "run"
      "--all"
    ];

    environment = {
      POSTGRES_HOST = "127.0.0.1";
      POSTGRES_PORT = "5432";
      POSTGRES_NAME = "bitmagnet";
      POSTGRES_USER = "bitmagnet";
      # POSTGRES_PASSWORD via env file
      REDIS_ADDR = ""; # Bitmagnet doesn't require Redis
    };
    environmentFiles = [ config.age.secrets.bitmagnet-db-pass.path ];

    volumes = [
      "/var/lib/bitmagnet:/root/.config/bitmagnet"
    ];

    extraOptions = [ "--network=host" ];

    podman.user = "bitmagnet";
    user = "0";
    # autoStart = false — the on-demand activator manages this.
    autoStart = false;
  };

  # Ensure the DB is available before Bitmagnet starts.
  systemd.services."podman-bitmagnet" = {
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = "10s";
    };
  };

  # /var/lib/bitmagnet is workload state: the stub, bind mount and ownership
  # come from modules/wiring/workload-gate.nix. Don't add a tmpfiles rule here.
}

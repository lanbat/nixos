# hosts/server/services/bitmagnet.nix
#
# Bitmagnet — DHT crawler and torrent search engine.
#
# On-demand: yes.
#   Bitmagnet is resource-intensive (crawls DHT constantly when running).
#   It runs on-demand via the activator pattern (see modules/server/on-demand.nix).
#   Caddy routes to the activator; the activator starts Bitmagnet on first
#   request and proxies transparently once it is healthy.
#   After 30 minutes idle, a systemd timer stops it.
#
# Storage:
#   /var/lib/bitmagnet/   — config, data (server-local)
#   PostgreSQL database   — shared instance, "bitmagnet" db
#
# No NFS dependency.
{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Bitmagnet container
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers.containers."bitmagnet" = {
    image = "ghcr.io/bitmagnet-io/bitmagnet:latest";

    environment = {
      POSTGRES_HOST     = "127.0.0.1";
      POSTGRES_PORT     = "5432";
      POSTGRES_NAME     = "bitmagnet";
      POSTGRES_USER     = "bitmagnet";
      # POSTGRES_PASSWORD via env file
      REDIS_ADDR        = ""; # Bitmagnet doesn't require Redis
    };
    # environmentFiles = [ ... ]; # add postgres password file here

    volumes = [
      "/var/lib/bitmagnet:/root/.config/bitmagnet"
    ];

    extraOptions = [ "--network=host" ];

    # autoStart = false — the on-demand activator manages this.
    autoStart = false;
  };

  # ---------------------------------------------------------------------------
  # On-demand activation
  # ---------------------------------------------------------------------------
  lanbat.onDemand.services.bitmagnet = {
    activatorPort = 3332;
    realPort      = 3333;
    targetService = "podman-bitmagnet.service";
    idleMinutes   = 30;
  };

  # Ensure the DB is available before Bitmagnet starts.
  systemd.services."podman-bitmagnet" = {
    after   = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    serviceConfig = {
      Restart    = lib.mkForce "on-failure";
      RestartSec = "10s";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/bitmagnet 0750 root root -"
  ];
}

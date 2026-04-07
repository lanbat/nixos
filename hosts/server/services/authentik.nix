# hosts/server/services/authentik.nix
#
# Authentik identity provider — SSO/OIDC/LDAP hub.
#
# Architecture
# ------------
# Authentik requires three processes:
#   1. authentik-server  — web UI + API (port 9000)
#   2. authentik-worker  — background jobs (email, flows, policies)
#
# Both share a PostgreSQL database and a Redis instance.
# They run as OCI containers with --network host so they can reach
# services.postgresql and services.redis.servers.authentik on localhost.
#
# Secret injection
# ----------------
# agenix decrypts secrets to /run/agenix/<name> at boot.
# The secrets must be stored as "KEY=value" lines so they can be passed
# directly as Docker/Podman environmentFiles.
#
#   authentik-env.age must contain:
#     AUTHENTIK_POSTGRESQL__PASSWORD=<value>
#     AUTHENTIK_SECRET_KEY=<value>
#
# See secrets/README.md for how to create this file.
#
# LDAP outpost
# ------------
# Authentik can run an embedded LDAP outpost (port 3389) for Samba.
# Enable it from the Authentik web UI under
# Applications → Outposts → Create LDAP Outpost.
#
# Caddy forward-auth outpost
# --------------------------
# The embedded outpost (built into authentik-server) handles the
# /outpost.goauthentik.io/auth/caddy path used by Caddy's forward_auth.
# After initial setup, create in the Authentik UI:
#   1. A "Proxy Provider" (type: Forward Auth / Single Application) per
#      protected service (Frigate, qBittorrent, Bitmagnet, Snapcast, Syncthing).
#   2. An "Application" linked to each provider.
#   3. Edit the embedded-outpost and add all proxy applications to it.
# See docs/deployment-checklist.md step 3b for the full walkthrough.
{ config, pkgs, lib, ... }:

let
  domain = config.lanbat.domain;

  # Authentik version — pin this and bump deliberately.
  authentikVersion = "2024.12.2";

  # Shared environment variables for both containers.
  # Secrets (PostgreSQL password + secret key) are injected via environmentFiles
  # from the agenix-decrypted file at /run/agenix/authentik-env.
  authentikEnv = {
    AUTHENTIK_REDIS__HOST         = "127.0.0.1";
    AUTHENTIK_REDIS__PORT         = "6379";
    AUTHENTIK_POSTGRESQL__HOST    = "127.0.0.1";
    AUTHENTIK_POSTGRESQL__USER    = "authentik";
    AUTHENTIK_POSTGRESQL__NAME    = "authentik";
    AUTHENTIK_ERROR_REPORTING__ENABLED = "false";
    AUTHENTIK_DISABLE_UPDATE_CHECK     = "true";
    AUTHENTIK_COOKIE_DOMAIN       = domain;
  };

  # Path to the agenix-decrypted env file.
  # File format (two lines):
  #   AUTHENTIK_POSTGRESQL__PASSWORD=<value>
  #   AUTHENTIK_SECRET_KEY=<value>
  authentikEnvFile = config.age.secrets.authentik-env.path;
in
{
  # ---------------------------------------------------------------------------
  # Authentik server container
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers.containers."authentik-server" = {
    image   = "ghcr.io/goauthentik/server:${authentikVersion}";
    cmd     = [ "server" ];
    extraOptions = [
      "--network=host"
      # Remap container UID/GID 1000 (authentik's internal user) to the host
      # "authentik" service account (UID/GID 998).  All other container UIDs
      # map into the sub-UID range so they cannot escape the user namespace.
      "--uidmap=0:1:1000"
      "--uidmap=1000:0:1"
      "--uidmap=1001:1001:64535"
      "--gidmap=0:1:1000"
      "--gidmap=1000:0:1"
      "--gidmap=1001:1001:64535"
    ];

    environment    = authentikEnv;
    environmentFiles = [ authentikEnvFile ];

    volumes = [
      "/var/lib/authentik/media:/media"
      "/var/lib/authentik/certs:/certs"
      "/var/lib/authentik/custom-templates:/templates"
    ];

    podman.user = "authentik";
    autoStart = true;
  };

  # ---------------------------------------------------------------------------
  # Authentik worker container
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers.containers."authentik-worker" = {
    image       = "ghcr.io/goauthentik/server:${authentikVersion}";
    cmd         = [ "worker" ];
    extraOptions = [
      "--network=host"
      "--uidmap=0:1:1000"
      "--uidmap=1000:0:1"
      "--uidmap=1001:1001:64535"
      "--gidmap=0:1:1000"
      "--gidmap=1000:0:1"
      "--gidmap=1001:1001:64535"
    ];

    environment    = authentikEnv;
    environmentFiles = [ authentikEnvFile ];

    volumes = [
      "/var/lib/authentik/media:/media"
      "/var/lib/authentik/certs:/certs"
    ];

    podman.user = "authentik";
    autoStart  = true;
    dependsOn  = [ "authentik-server" ];
  };

  # ---------------------------------------------------------------------------
  # State directories
  # ---------------------------------------------------------------------------
  # The --uidmap flags remap container UID 1000 → host "authentik" (UID 998),
  # so directories must be owned by the "authentik" service account on the host.
  # Inside the container, these appear as owned by UID 1000 as Authentik expects.
  systemd.tmpfiles.rules = [
    "d /var/lib/authentik                        0750 authentik authentik -"
    "d /var/lib/authentik/media                  0750 authentik authentik -"
    "d /var/lib/authentik/media/public           0750 authentik authentik -"
    "d /var/lib/authentik/certs                  0750 authentik authentik -"
    "d /var/lib/authentik/custom-templates       0750 authentik authentik -"
  ];

  # Authentik waits for PostgreSQL and Redis before starting.
  systemd.services."podman-authentik-server" = {
    after    = [ "postgresql.service" "redis-authentik.service" ];
    requires = [ "postgresql.service" "redis-authentik.service" ];
  };
  systemd.services."podman-authentik-worker" = {
    after    = [ "postgresql.service" "redis-authentik.service" ];
    requires = [ "postgresql.service" "redis-authentik.service" ];
  };
}

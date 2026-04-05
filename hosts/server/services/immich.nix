# hosts/server/services/immich.nix
#
# Immich — self-hosted photo/video library.
#
# Why fully containerized?
#   Immich requires pgvecto.rs (a PostgreSQL extension) which is not in
#   standard nixpkgs PostgreSQL packages.  Using Immich's own postgres
#   container (which ships pgvecto.rs) is far simpler than patching the
#   NixOS postgresql module.
#
# Storage split
# -------------
# Server-local (always-on):
#   /var/lib/immich/db/           — PostgreSQL data (pgvecto.rs)
#   /var/lib/immich/model-cache/  — ML model cache (~4 GB on first run)
#   /var/lib/immich/thumbs/       — generated thumbnails
#   /var/lib/immich/encoded-video/— re-encoded videos
#   /var/lib/immich/profile/      — user profile pictures
#   Redis (services.redis.servers.immich)
#
# Pi-backed via NFS (/srv/storage/a):
#   /srv/storage/a/photos/        — originals / uploads (bulk)
#
# NFS dependency: partial.
#   - If Pi is down: Immich is still up, new uploads fail, existing
#     thumbnails (server-local) still load.
#   - The immich-server container binds /srv/storage/a/photos.
#     We declare that dependency so Immich stops if the mount disappears.
#
# Auth: Immich has native OIDC support (v1.91+). Configure Authentik as
# the OIDC provider pointing to https://photos.<domain>/auth/login.
{ config, pkgs, lib, ... }:

let
  immichVersion   = "release"; # CHANGE_ME: pin to a specific tag, e.g. "v1.118.2"
  immichDbVersion = "14-vectorchord0.4.3-pgvectors0.2.0"; # matches official immich docker-compose
  domain          = config.lanbat.domain;
in
{
  # ---------------------------------------------------------------------------
  # PostgreSQL for Immich (containerized — pgvecto.rs / vectorchord required)
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers.containers."immich-postgres" = {
    image = "ghcr.io/immich-app/postgres:${immichDbVersion}";
    environment = {
      POSTGRES_USER     = "immich";
      POSTGRES_DB       = "immich";
      POSTGRES_INITDB_ARGS = "--data-checksums";
    };
    environmentFiles = [ config.age.secrets.immich-db-password.path ];
    # POSTGRES_PASSWORD must be set in the secret file:
    #   POSTGRES_PASSWORD=<value>
    volumes = [ "/var/lib/immich/db:/var/lib/postgresql/data" ];
    extraOptions = [
      "--network=host"
      "--shm-size=128m"
    ];
    autoStart = true;
  };

  # ---------------------------------------------------------------------------
  # Immich server container
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers.containers."immich-server" = {
    image   = "ghcr.io/immich-app/immich-server:${immichVersion}";
    extraOptions = [ "--network=host" ];
    environment = {
      DB_HOSTNAME      = "127.0.0.1";
      DB_PORT          = "5432";
      DB_USERNAME      = "immich";
      DB_DATABASE_NAME = "immich";
      REDIS_HOSTNAME   = "127.0.0.1";
      REDIS_PORT       = "6380";
      UPLOAD_LOCATION  = "/usr/src/app/upload";
      THUMBS_PATH      = "/usr/src/app/thumbs";
      ENCODED_VIDEO_PATH = "/usr/src/app/encoded-video";
      PROFILE_PATH     = "/usr/src/app/profile";

      # OIDC / OAuth2 — configure Authentik as the provider.
      # These values are populated from the agenix secret below once the
      # Authentik application is created (see docs/authentik-setup.md).
      # The env file must export:
      #   POSTGRES_PASSWORD=<value>
      #   IMMICH_OAUTH_CLIENT_ID=<value>
      #   IMMICH_OAUTH_CLIENT_SECRET=<value>
      IMMICH_OAUTH_ENABLED          = "true";
      IMMICH_OAUTH_ISSUER_URL       = "https://auth.${domain}/application/o/immich/";
      IMMICH_OAUTH_SCOPE            = "openid profile email";
      IMMICH_OAUTH_SIGN_IN_BUTTON_TEXT = "Login with Authentik";
      IMMICH_OAUTH_AUTO_REGISTER    = "true";
      # Immich binds on port 2283 by default.
    };
    environmentFiles = [
      config.age.secrets.immich-db-password.path
      # immich-oidc-env.age exports IMMICH_OAUTH_CLIENT_ID and
      # IMMICH_OAUTH_CLIENT_SECRET.  Create this secret once you have the
      # Authentik application credentials.
      config.age.secrets.immich-oidc-env.path
    ];
    volumes = [
      "/srv/storage/a/photos:/usr/src/app/upload"
      "/var/lib/immich/thumbs:/usr/src/app/thumbs"
      "/var/lib/immich/encoded-video:/usr/src/app/encoded-video"
      "/var/lib/immich/profile:/usr/src/app/profile"
      "/etc/localtime:/etc/localtime:ro"
    ];
    dependsOn  = [ "immich-postgres" ];
    autoStart  = true;
  };

  # ---------------------------------------------------------------------------
  # Immich machine learning container
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers.containers."immich-machine-learning" = {
    image   = "ghcr.io/immich-app/immich-machine-learning:${immichVersion}";
    extraOptions = [ "--network=host" ];
    environment = {
      # ML service binds on 3003 by default; server reaches it on localhost.
      MACHINE_LEARNING_WORKERS       = "1";
      MACHINE_LEARNING_WORKER_TIMEOUT = "120";
    };
    volumes = [
      "/var/lib/immich/model-cache:/cache"
    ];
    dependsOn  = [ "immich-server" ];
    autoStart  = true;
  };

  # ---------------------------------------------------------------------------
  # NFS dependency for immich-server
  # ---------------------------------------------------------------------------
  # Immich server accesses /srv/storage/a/photos.
  # If that mount disappears, we want Immich server to stop and restart
  # when the mount comes back.
  lanbat.nfsDependentServices."podman-immich-server" = [ "a" ];

  # Ensure the photo path exists when NFS is mounted.
  systemd.tmpfiles.rules = [
    "d /srv/storage/a/photos 0750 immich immich -"
  ];
}

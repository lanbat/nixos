# services/immich.nix
#
# Immich — self-hosted photo/video library.
#
# Storage split
# -------------
# Server-local (always-on):
#   /var/lib/postgresql/          — PostgreSQL data (shared instance, vectorchord)
#   /var/lib/immich/model-cache/  — ML model cache (~4 GB on first run)
#   /var/lib/immich/thumbs/       — generated thumbnails
#   /var/lib/immich/encoded-video/— re-encoded videos
#   /var/lib/immich/profile/      — user profile pictures
#   Redis (services.redis.servers.immich)
#
# Pi-backed via NFS (/srv/storage/b/users/<user>/photos/):
#   Per-user photo libraries via Immich external libraries (unified quota).
#
# NFS dependency: partial.
#   - If Pi is down: Immich is still up, new uploads fail, existing
#     thumbnails (server-local) still load.
#   - The immich-server container binds /srv/storage/a/photos.
#     We declare that dependency so Immich stops if the mount disappears.
#
# Auth with Authentik
# -------------------
# Browser access is gated by Caddy forward-auth (Authentik session), like Home
# Assistant.  Immich v3 reads OAuth settings from IMMICH_CONFIG_FILE (not env
# vars); a preStart hook writes that file from immich-oidc-env.age.
# Mobile apps keep using /api/* with Immich credentials (apiClients bypass).
#
# Immich requires a local admin record before OAuth auto-launch works; the
# immich-bootstrap oneshot creates that admin (email must match Authentik) and
# password login is disabled so the browser only uses OIDC.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  immichVersion = "release"; # CHANGE_ME: pin to a specific tag, e.g. "v1.118.2"
  domain = config.lanbat.domain;
  bootstrap = pkgs.callPackage ../pkgs/immich-bootstrap { };
  # immich-db-password.age exports POSTGRES_PASSWORD for postgres init; Immich v3
  # reads DB_PASSWORD at runtime.
  immichServerEnv = "/run/immich/server.env";
  immichConfigPath = "/run/immich/config.json";
  immichConfigMount = "/config/immich-config.json";
  # Immich reaches Authentik over https://auth.<domain> during OAuth discovery.
  lanbatCaBundle = "/var/lib/caddy-local-ca/ca-certificates.crt";
  lanbatCaBundleMount = "/etc/ssl/lanbat/ca-certificates.crt";
  lanbatCaRootMount = "/etc/ssl/lanbat/ca-root.crt";
in
{
  config = {
    # The option is declared in modules/core/settings.nix, since local.nix is
    # shared by both hosts.
    lanbat.immich.adminEmail = lib.mkDefault (
      "${lib.elemAt config.lanbat.homeAssistant.ssoUsers 0}@${config.lanbat.rootDomain}"
    );

    lanbat.services.immich = {
      subdomain = "photos";
      port = 2283;
      extraPorts = [ 3003 ]; # machine learning
      auth = "forward-auth";
      apiClients = true; # mobile app — /api/* bypasses Authentik at Caddy
      tier = "workload";
      state = [ "immich" ];
      units = [
        "podman-immich-server"
        "podman-immich-machine-learning"
        "immich-bootstrap"
      ];
      # Podman requires volume host paths to exist before the container starts.
      workloadDirs =
        lib.genAttrs
          [
            "immich"
            "immich/thumbs"
            "immich/encoded-video"
            "immich/profile"
            "immich/model-cache"
            "immich/upload"
          ]
          (_: {
            user = "immich";
          });
      # User photo libraries live under the unified per-user storage tree.
      nfs = {
        drives = [ "b" ];
        units = [ "podman-immich-server" ];
      };
      account = {
        uid = 991;
        container = true;
      };
      secrets = {
        # group postgres: postgresql-immich-init reads the password too.
        immich-db-password = {
          group = "postgres";
          mode = "0440";
        };
        immich-oidc-env = { };
      };
      dashboard = {
        group = "Media";
        name = "Immich";
        description = "Photo library";
        widget = {
          type = "immich";
          key = "CHANGE_ME_IMMICH_API_KEY";
        };
      };
    };

    lanbat.postgresql.databases.immich = {
      instance = "workload";
      passwordFile = config.age.secrets.immich-db-password.path;
      extraSql = ''
        CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
        CREATE EXTENSION IF NOT EXISTS cube;
        CREATE EXTENSION IF NOT EXISTS earthdistance;
      '';
    };

    # ---------------------------------------------------------------------------
    # Immich server container
    # ---------------------------------------------------------------------------
    virtualisation.oci-containers.containers."immich-server" = {
      image = "ghcr.io/immich-app/immich-server:${immichVersion}";
      extraOptions = [ "--network=host" ];
      podman.user = "immich";
      user = "0";
      environment = {
        DB_HOSTNAME = "127.0.0.1";
        DB_PORT = "5432";
        DB_USERNAME = "immich";
        DB_DATABASE_NAME = "immich";
        REDIS_HOSTNAME = "127.0.0.1";
        REDIS_PORT = "6379";
        REDIS_DBINDEX = "1";
        UPLOAD_LOCATION = "/usr/src/app/upload";
        THUMBS_PATH = "/usr/src/app/thumbs";
        ENCODED_VIDEO_PATH = "/usr/src/app/encoded-video";
        PROFILE_PATH = "/usr/src/app/profile";
        IMMICH_CONFIG_FILE = immichConfigMount;
        # Node fetch for OIDC discovery does not inherit the host trust store.
        NODE_EXTRA_CA_CERTS = lanbatCaRootMount;
        SSL_CERT_FILE = lanbatCaBundleMount;
      };
      environmentFiles = [
        immichServerEnv
        config.age.secrets.immich-oidc-env.path
      ];
      volumes = [
        "/var/lib/immich/upload:/usr/src/app/upload"
        "${config.lanbat.userStorage.mountOnServer}:/usr/src/app/user-storage"
        "/var/lib/immich/thumbs:/usr/src/app/thumbs"
        "/var/lib/immich/encoded-video:/usr/src/app/encoded-video"
        "/var/lib/immich/profile:/usr/src/app/profile"
        "${immichConfigPath}:${immichConfigMount}:ro"
        "/etc/localtime:/etc/localtime:ro"
        "/etc/caddy/ca-root.crt:${lanbatCaRootMount}:ro"
        "${lanbatCaBundle}:${lanbatCaBundleMount}:ro"
      ];
      autoStart = true;
    };

    # ---------------------------------------------------------------------------
    # Immich machine learning container
    # ---------------------------------------------------------------------------
    virtualisation.oci-containers.containers."immich-machine-learning" = {
      image = "ghcr.io/immich-app/immich-machine-learning:${immichVersion}";
      extraOptions = [ "--network=host" ];
      podman.user = "immich";
      user = "0";
      environment = {
        # ML service binds on 3003 by default; server reaches it on localhost.
        MACHINE_LEARNING_WORKERS = "1";
        MACHINE_LEARNING_WORKER_TIMEOUT = "120";
      };
      volumes = [
        "/var/lib/immich/model-cache:/cache"
      ];
      dependsOn = [ "immich-server" ];
      autoStart = true;
    };

    systemd.services.podman-immich-server = {
      path = [ pkgs.jq ];
      preStart = ''
        set -euo pipefail
        install -d -m 0750 -o immich -g immich /run/immich
        umask 0177
        . ${config.age.secrets.immich-db-password.path}
        printf 'DB_PASSWORD=%s\n' "$POSTGRES_PASSWORD" > ${immichServerEnv}
        chown immich:immich ${immichServerEnv}

        set -a
        . ${config.age.secrets.immich-oidc-env.path}
        set +a
        ${pkgs.jq}/bin/jq -n \
          --arg issuer "https://auth.${domain}/application/o/immich/" \
          --arg clientId "$IMMICH_OAUTH_CLIENT_ID" \
          --arg clientSecret "$IMMICH_OAUTH_CLIENT_SECRET" \
          --arg externalDomain "https://photos.${domain}" \
          '{
            oauth: {
              enabled: true,
              issuerUrl: $issuer,
              clientId: $clientId,
              clientSecret: $clientSecret,
              scope: "openid email profile",
              buttonText: "Login with Authentik",
              autoRegister: true,
              autoLaunch: true,
              tokenEndpointAuthMethod: "client_secret_post"
            },
            passwordLogin: {
              enabled: false
            },
            server: {
              externalDomain: $externalDomain
            }
          }' > ${immichConfigPath}
        chown immich:immich ${immichConfigPath}
      '';
    };

    systemd.services.immich-bootstrap = {
      description = "Create the first Immich admin for Authentik OAuth login";
      wantedBy = [ "multi-user.target" ];
      after = [ "podman-immich-server.service" ];
      wants = [ "podman-immich-server.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
      };

      path = [ bootstrap ];

      script = ''
        set -a
        . ${config.age.secrets.hass-bootstrap-env.path}
        set +a
        export IMMICH_URL="http://127.0.0.1:2283"
        export ADMIN_EMAIL="${config.lanbat.immich.adminEmail}"
        export ADMIN_NAME="$OWNER_USERNAME"
        export ADMIN_PASSWORD="$OWNER_PASSWORD"
        exec immich-bootstrap
      '';
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/immich/upload 0750 immich immich -"
      "d /run/immich 0750 immich immich -"
    ];
  };
}

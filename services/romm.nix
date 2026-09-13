# services/romm.nix
#
# RomM — web ROM manager: browse the ROM library, scrape its metadata and
# artwork, and play in the browser.
#
# On-demand: yes (modules/wiring/on-demand.nix). Caddy routes to the
# activator, which starts RomM on the first request; it stops after 30
# minutes idle.
#
# Storage:
#   /var/lib/romm/config/     — config.yml (seeded on first start, then edited
#                               from RomM's settings)
#   /var/lib/romm/resources/  — scraped artwork and metadata
#   /var/lib/romm/assets/     — uploaded saves, states and screenshots
#   /srv/storage/b/media/roms — the ROM library on the Pi, in ES-DE's layout
#                               (roms/<system>), shared with EmulationStation
#                               on the TV. qBittorrent saves ROM torrents there.
#   Workload PostgreSQL        — "romm" database
#   Shared Redis               — database 2 (Authentik uses 0, Immich 1)
#
# Auth: Caddy forward auth (Authentik), then RomM's own accounts. The first
# visit runs RomM's setup wizard, which creates the admin account.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  port = 8098;
  workloadDb = config.lanbat.postgresql.instances.workload;

  # ES-DE's folder names are RomM's platform names, except atari800. bios is
  # RetroArch's BIOS folder (modules/pi/tv.nix), not a platform.
  seedConfig = pkgs.writeText "romm-config.yml" ''
    exclude:
      platforms:
        - "bios"
      roms:
        single_file:
          extensions:
            - "xml"
            - "txt"
          names:
            - "info.txt"
            - "metadata.txt"
            - "systeminfo.txt"
            - "._*"
            # qBittorrent's partial pieces and unfinished files
            - ".*.parts"
            - "*.!qB"
        multi_file:
          names:
            - "roms"
            - ".Trash*"
    system:
      platforms:
        atari800: "atari8bit"
  '';
in
{
  lanbat.services.romm = {
    subdomain = "romm";
    inherit port;
    auth = "forward-auth";
    tier = "workload";
    state = [ "romm" ];
    units = [ "podman-romm" ];
    workloadDirs = lib.genAttrs [ "romm" "romm/config" "romm/resources" "romm/assets" ] (_: {
      user = "romm";
    });
    nfs.drives = [ "b" ];
    onDemand = {
      activatorPort = 8094;
      idleMinutes = 30;
    };
    account = {
      uid = 965;
      container = true;
      # The library on the Pi belongs to qbt, group media (modules/pi/storage.nix).
      extraGroups = [ "media" ];
    };
    secrets = {
      # POSTGRES_PASSWORD for the database setup, DB_PASSWD for RomM.
      romm-db-pass = {
        group = "postgres";
        mode = "0440";
      };
      # ROMM_AUTH_SECRET_KEY and the metadata provider keys.
      romm-env = { };
    };
    dashboard = {
      group = "Media";
      name = "RomM";
      description = "ROM library (on-demand)";
    };
  };

  lanbat.postgresql.databases.romm = {
    instance = "workload";
    passwordFile = config.age.secrets.romm-db-pass.path;
  };

  virtualisation.oci-containers.containers."romm" = {
    image = "docker.io/rommapp/romm:5";

    environment = {
      ROMM_PORT = toString port;
      ROMM_BASE_URL = "https://romm.${config.lanbat.domain}";
      ROMM_SESSION_SECURE_COOKIE = "true";
      ROMM_DB_DRIVER = "postgresql";
      DB_HOST = "127.0.0.1";
      DB_PORT = toString workloadDb.port;
      DB_NAME = "romm";
      DB_USER = "romm";
      # The shared Redis: RomM's internal Valkey would listen on 6379 too.
      REDIS_HOST = "127.0.0.1";
      REDIS_PORT = "6379";
      REDIS_DB = "2";
      HASHEOUS_API_ENABLED = "true";
      LAUNCHBOX_API_ENABLED = "true";
      TZ = config.lanbat.timezone;
    };
    environmentFiles = [
      config.age.secrets.romm-db-pass.path
      config.age.secrets.romm-env.path
    ];

    volumes = [
      "/var/lib/romm/config:/romm/config"
      "/var/lib/romm/resources:/romm/resources"
      "/var/lib/romm/assets:/romm/assets"
      "/srv/storage/b/media/roms:/romm/library/roms"
    ];

    extraOptions = [
      # Reaches PostgreSQL and Redis on the server's loopback, like Bitmagnet.
      "--network=host"
      # Keeps the media group, for the library on the Pi.
      "--group-add=keep-groups"
    ];

    podman.user = "romm";
    user = "0";
    # The on-demand activator starts it.
    autoStart = false;
  };

  systemd.services."podman-romm" = {
    after = [ workloadDb.unit ];
    requires = [ workloadDb.unit ];
    preStart = ''
      if [ ! -e /var/lib/romm/config/config.yml ]; then
        install -m 0644 ${seedConfig} /var/lib/romm/config/config.yml
      fi
    '';
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = "10s";
    };
  };
}

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
#   /srv/storage/b/media/roms-browser/mame
#                             — zip copies of the arcade sets, which RomM shows
#                               in place of roms/mame (below)
#   Workload PostgreSQL        — "romm" database
#   Shared Redis               — database 2 (Authentik uses 0, Immich 1)
#
# Auth: Caddy forward auth (Authentik), then RomM's own accounts. The first
# visit runs RomM's setup wizard, which creates the admin account.
#
# Arcade games in the browser
# ---------------------------
# The library's MAME sets are 7z, which the browser emulator's arcade cores
# can't read, and a game needing a BIOS (Neo Geo) only finds it inside its own
# archive. romm-browser-romsets builds a zip of each set with its parent and
# BIOS sets' files (pkgs/romm-browser-romsets), hourly, and RomM's mame folder
# is that directory. In RomM's player, pick the FinalBurn Neo core once per
# browser: RomM's default arcade core, MAME 2003, crashes on these sets.
# Dreamcast games can't run in the browser; the TV plays them.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  port = 8098;
  # gunicorn behind the container's nginx. Its default, 5000, is Frigate's on
  # the host network.
  backendPort = 8100;
  workloadDb = config.lanbat.postgresql.instances.workload;

  library = "/srv/storage/b/media/roms";
  browserArcade = "/srv/storage/b/media/roms-browser/mame";
  browserRomsets = pkgs.callPackage ../pkgs/romm-browser-romsets { };

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
    extraPorts = [ backendPort ];
    auth = "forward-auth";
    tier = "workload";
    state = [ "romm" ];
    units = [ "podman-romm" ];
    workloadDirs = lib.genAttrs [ "romm" "romm/config" "romm/resources" "romm/assets" ] (_: {
      user = "romm";
    });
    nfs = {
      drives = [ "b" ];
      units = [
        "podman-romm"
        "romm-browser-romsets"
      ];
    };
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
      # The entrypoint also points nginx's upstream at it.
      DEV_PORT = toString backendPort;
      ROMM_BASE_URL = "https://romm.${config.lanbat.deployment.domain}";
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
      # Picks up the zips romm-browser-romsets adds or replaces.
      ENABLE_RESCAN_ON_FILESYSTEM_CHANGE = "true";
      TZ = config.lanbat.deployment.timezone;
    };
    environmentFiles = [
      config.age.secrets.romm-db-pass.path
      config.age.secrets.romm-env.path
    ];

    volumes = [
      "/var/lib/romm/config:/romm/config"
      "/var/lib/romm/resources:/romm/resources"
      "/var/lib/romm/assets:/romm/assets"
      "${library}:/romm/library/roms"
      # After the library, so it covers the library's mame folder.
      "${browserArcade}:/romm/library/roms/mame"
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
      # podman won't mount a missing directory; it fills on the next build.
      install -d -m 2775 ${browserArcade}
    '';
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = "10s";
    };
  };

  # Zip copies of the arcade sets for the browser player (see the top).
  systemd.services.romm-browser-romsets = {
    description = "Build RomM's browser copies of the arcade romsets";
    environment = {
      SOURCE_DIR = "${library}/mame";
      TARGET_DIR = browserArcade;
      FBNEO_DAT = browserRomsets.dat;
      SEVENZIP = "${pkgs.p7zip}/bin/7z";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${browserRomsets}/bin/romm-browser-romsets";
      User = "romm";
      # The library's group, so the zips are readable like the rest of it.
      Group = "media";
      UMask = "0002";
      PrivateTmp = true;
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.romm-browser-romsets = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "1h";
    };
  };
}

# services/audiobookshelf.nix
#
# Audiobookshelf — audiobook server with phone apps that sync listening
# progress.
#
# Why, next to Jellyfin?
#   Jellyfin shows an audiobook in several files as one item per file and has
#   no online metadata for audiobooks. Audiobookshelf groups a book's files,
#   fetches its details and cover (Audible by default), and its apps keep the
#   place in a book across devices. Jellyfin's Audiobooks library still reads
#   the same folder.
#
# Why the NixOS module?
#   `services.audiobookshelf` runs the upstream server as its own user; there
#   is no reason to containerize.
#
# Storage:
#   /var/lib/audiobookshelf/     — database, per-book metadata and covers,
#                                  listening progress (workload layer)
#   /srv/storage/<drive>/<libraryPath>
#                                — the audiobooks on the Pi, read in place:
#                                  <author>/<title>/<files>, or
#                                  <author>/<series>/<title>/<files>
#
# NFS has no inotify, so the library's file watcher is off and it is scanned
# every two hours instead, like Jellyfin's libraries.
#
# Settings (lanbat.services.audiobookshelf.settings): drive and libraryPath
# place the library, metadataProvider picks where book details come from.
#
# Auth: Audiobookshelf's own accounts. audiobookshelf-bootstrap creates the
# root account from Home Assistant's owner (hass-bootstrap-env, the break-glass
# login, as for Jellyfin) and signs users in through Authentik OIDC, matching
# an existing account by username and creating one for anyone else Authentik
# lets in. The apps log in the same way (apiClients = true, no forward auth).
#
# Metadata: audiobookshelf-match runs "Match books" after the bootstrap's
# scan at each unlock, and nightly for books added since. A book already
# matched (it has an ASIN or ISBN) is left alone, and matching only fills in
# what the files' tags lack.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  domain = config.lanbat.deployment.domain;
  port = 13378;
  cfg = config.lanbat.services.audiobookshelf.settings;
  bootstrap = pkgs.callPackage ../pkgs/audiobookshelf-bootstrap { };

  # Where the server mounts a Pi storage drive (modules/wiring/nfs.nix).
  library = "/srv/storage/${cfg.drive}/${cfg.libraryPath}";

  # The bootstrap reads secrets that home-assistant.nix and authentik own, so
  # it can only exist when those services are part of the deployment.
  integrates = config.lanbat.hasService "home-assistant" && config.lanbat.hasService "authentik";

  audiobookshelfSettings = {
    options = {
      drive = lib.mkOption {
        type = lib.types.str;
        default = "b";
        description = ''
          Pi storage drive holding the audiobooks, by its key in the storage
          host's storage.drives. Audiobookshelf binds to that drive's NFS mount.
        '';
      };
      libraryPath = lib.mkOption {
        type = lib.types.str;
        default = "media/audiobooks";
        description = ''
          The audiobooks folder, relative to the drive's mount
          (/srv/storage/<drive>). Jellyfin's Audiobooks library reads the same
          folder.
        '';
      };
      metadataProvider = lib.mkOption {
        type = lib.types.enum [
          "audible"
          "audible.ca"
          "audible.uk"
          "audible.au"
          "audible.fr"
          "audible.de"
          "audible.jp"
          "audible.it"
          "audible.in"
          "audible.es"
          "google"
          "openlibrary"
          "itunes"
          "fantlab"
        ];
        default = "audible";
        description = ''
          Where "Match books" looks up a book's details and cover. Pick the
          Audible store of the country the books were bought in.
        '';
      };
    };
  };

  env = {
    ABS_URL = "http://127.0.0.1:${toString port}";
    AUTH_URL = "https://auth.${domain}";
    EXTERNAL_URL = "https://${config.lanbat.services.audiobookshelf.subdomain}.${domain}";
    LIBRARY_PATH = library;
    METADATA_PROVIDER = cfg.metadataProvider;
  };

  # Both units sign in as the owner; the bootstrap also configures OIDC.
  loadSecrets = ''
    set -a
    . ${config.lanbat.secrets.hass-bootstrap-env.path}
    . ${config.lanbat.secrets.authentik-oidc-secrets.path}
    set +a
  '';
in
{
  # The schema is merged into lanbat.services.audiobookshelf.settings; checks.nix
  # rejects any key it does not declare.
  lanbat.settingsSchema.audiobookshelf = audiobookshelfSettings;

  lanbat.services.audiobookshelf = {
    subdomain = "audiobooks";
    inherit port;
    auth = "app";
    apiClients = true; # the Audiobookshelf phone apps
    # The browser's callback, and the one the apps go through before
    # Audiobookshelf hands them back to audiobookshelf://oauth.
    oidc.redirectPaths = [
      "/auth/openid/callback"
      "/auth/openid/mobile-redirect"
    ];
    readsSecrets = lib.optionals integrates [
      "hass-bootstrap-env"
      "authentik-oidc-secrets"
    ];
    tier = "workload";
    state = [ "audiobookshelf" ];
    units = [
      "audiobookshelf"
    ]
    ++ lib.optionals integrates [
      "audiobookshelf-bootstrap"
      "audiobookshelf-match"
    ]
    # Music Assistant's Audiobookshelf provider (services/music-assistant.nix)
    # can only be added while this server is up, so it runs with the layer.
    ++ lib.optional (
      integrates && config.lanbat.hasService "music-assistant"
    ) "music-assistant-audiobookshelf";
    consumes = lib.optionals integrates [
      "home-assistant"
      "authentik"
    ];
    workloadDirs."audiobookshelf".user = "audiobookshelf";
    nfs.drives = [ cfg.drive ];
    account = {
      uid = 966;
      # The audiobooks on the Pi belong to qbt, group media (modules/storage/storage.nix).
      extraGroups = [ "media" ];
    };
    dashboard = {
      group = "Media";
      name = "Audiobookshelf";
      description = "Audiobooks";
    };
  };

  services.audiobookshelf = {
    enable = true;
    host = "127.0.0.1";
    inherit port;
  };

  systemd.services.audiobookshelf = {
    # Token exchange with Authentik, whose certificate Caddy's internal CA
    # issues.
    environment.NODE_EXTRA_CA_CERTS = "/etc/caddy/ca-root.crt";
    serviceConfig.RestartSec = "15s";
  };

  systemd.services.audiobookshelf-bootstrap = lib.mkIf integrates {
    description = "Complete Audiobookshelf setup (root account, library, OIDC)";
    wantedBy = [ "multi-user.target" ];
    after = [ "audiobookshelf.service" ];
    wants = [ "audiobookshelf.service" ];
    environment = env;
    path = [ bootstrap ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "30s";
    };
    script = ''
      ${loadSecrets}
      exec audiobookshelf-bootstrap
    '';
  };

  # At unlock (the workload gate starts it) after the bootstrap's scan, and
  # nightly for books added since.
  systemd.services.audiobookshelf-match = lib.mkIf integrates {
    description = "Match Audiobookshelf's new books against ${cfg.metadataProvider}";
    after = [ "audiobookshelf-bootstrap.service" ];
    requires = [ "audiobookshelf.service" ];
    environment = env // {
      MATCH_ONLY = "1";
    };
    path = [ bootstrap ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${loadSecrets}
      exec audiobookshelf-bootstrap
    '';
  };

  systemd.timers.audiobookshelf-match = lib.mkIf integrates {
    # Only while the workload layer is unlocked, like the service it starts.
    wantedBy = [ "workload-online.target" ];
    partOf = [ "workload-online.target" ];
    timerConfig = {
      OnCalendar = "04:30";
      RandomizedDelaySec = "30min";
    };
  };
}

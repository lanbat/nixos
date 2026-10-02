# tests/service-settings.nix
#
# Service settings schemas other than Frigate's (tests/frigate-settings.nix).
# Pure evaluation of the example profile, and of variants of it whose server
# carries one more module, as a profile's hosts.<key>.modules would:
#
#   - Samba: the default share layout renders as before; a profile adds,
#     changes and drops shares field by field, smbd binds to the NFS mounts of
#     exactly the drives the shares use, and an unknown key is rejected.
#   - Wyoming: the defaults keep today's pipeline and server satellite, and a
#     profile's voice, model and ALSA card reach the servers, the satellite and
#     Home Assistant's pipeline.
#   - Home Assistant: the loopback URLs of the services it wires come from
#     their descriptions, and the Zigbee2MQTT bridge watch follows whether
#     Zigbee2MQTT runs on the host unless the profile says otherwise.
#   - Telegraf: InfluxDB, Redis and the health checks are reached at the ports
#     the services' descriptions give, and a profile sets the ping targets.
#   - RomM: the library and the browser's arcade copies default to drive b's
#     media/roms and media/roms-browser/mame, a profile moves them, and the
#     NFS dependency follows the drive.
#   - Music Assistant: its setup reaches Music Assistant and Home Assistant at
#     the ports and subdomains of their descriptions.
#   - Immich: the originals default to drive a's photos, a profile moves them
#     and the NFS dependency follows; PostgreSQL, Redis and its own API are
#     reached at the ports of their descriptions.
#   - Grafana: its InfluxDB datasource follows InfluxDB's endpoint port.
#   - Nextcloud: the bulk data directories default to drive b's nextcloud,
#     and a profile moves them.
#   - Jellyfin: IMVDb is off and needs no key by default; settings.imvdb
#     requires jellyfin-imvdb-env and hands it to jellyfin-bootstrap.
#   - Audiobookshelf: the library defaults to drive b's media/audiobooks and
#     Audible, a profile moves it and picks another provider, and the NFS
#     dependency follows the drive.
#   - The Redis index registry keeps today's indexes and rejects a clash, and
#     Nextcloud's database is the workload instance's "nextcloud" over its
#     socket, as database.createLocally made it.
{
  lib,
  pkgs,
  inputs,
  self,
  agenix,
  disko,
  deploy-rs,
  nixpkgs,
  nixos-raspberrypi,
}:

let
  inputsWithSelf = inputs // {
    self = self // {
      lanbatPlugins = import ../plugins;
    };
  };

  exampleDeploy = import ../deployments/example/deploy.nix { inputs = inputsWithSelf; };

  lanbatLib = import ../lib {
    self = inputsWithSelf.self;
    inputs = inputsWithSelf;
    profiles = { };
    inherit
      nixpkgs
      nixos-raspberrypi
      agenix
      disko
      deploy-rs
      ;
  };

  # The example server's configuration, with extra modules merged last.
  serverWith =
    modules:
    let
      deploy = exampleDeploy // {
        hosts = exampleDeploy.hosts // {
          server = exampleDeploy.hosts.server // {
            modules = (exampleDeploy.hosts.server.modules or [ ]) ++ modules;
          };
        };
      };
    in
    (lanbatLib.mkProfile "example" deploy).configurations.example-server.config;

  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);

  base = serverWith [ ];

  # ── Samba ────────────────────────────────────────────────────────────────
  smb = config: config.services.samba.settings;
  sambaDrives = config: config.lanbat.services.samba.nfs.drives;

  sambaChanged = serverWith [
    {
      lanbat.services.samba.settings = {
        workgroup = "LAB";
        shares = {
          private.enable = false;
          # Only the mode: the default owner and group stay.
          shared.createDirectory.mode = "0770";
          media-b.vetoFiles = [
            "adult"
            "tmp"
          ];
          scans = {
            drive = "a";
            path = "scans";
            readOnly = false;
            validUsers = [ "@media" ];
            extraConfig."hide dot files" = "yes";
          };
        };
      };
    }
  ];

  sambaDriveA = serverWith [
    {
      lanbat.services.samba.settings = {
        homes = false;
        shares = {
          media-b.enable = false;
          private.enable = false;
          shared.enable = false;
        };
      };
    }
  ];

  sambaTypo = serverWith [ { lanbat.services.samba.settings.share = { }; } ];

  # ── Wyoming ──────────────────────────────────────────────────────────────
  wyomingChanged = serverWith [
    {
      lanbat.services.wyoming.settings = {
        wakeWord.threshold = 0.5;
        speechToText = {
          model = "small-int8";
          language = "de";
        };
        textToSpeech.voice = "de_DE-thorsten-medium";
        satellite = {
          name = "Office Satellite";
          speaker = "plughw:CARD=Generic,DEV=0";
          mixer = [ ];
          microphoneUsbId = "046d:0825";
        };
      };
    }
  ];

  wyomingBadVoice = serverWith [ { lanbat.services.wyoming.settings.textToSpeech.voice = "alan"; } ];

  postSetup = config: config.systemd.services.home-assistant-post-setup.script;

  # ── Home Assistant ───────────────────────────────────────────────────────
  haConfig = config: config.services.home-assistant.config;
  haViews = config: map (v: v.path) config.services.home-assistant.lovelaceConfig.views;

  haMoved = serverWith [
    {
      lanbat.services = {
        home-assistant.port = lib.mkForce 18123;
        frigate.port = lib.mkForce 15000;
        music-assistant.port = lib.mkForce 18095;
        mosquitto.endpoint.port = lib.mkForce 11883;
      };
    }
  ];

  haNoZigbee = serverWith [
    { lanbat.services.home-assistant.settings.zigbee2mqttBridge = false; }
  ];

  # ── Jellyfin ─────────────────────────────────────────────────────────────
  jellyfinBootstrap = config: config.systemd.services.jellyfin-bootstrap.script;

  jellyfinImvdb = serverWith [ { lanbat.services.jellyfin.settings.imvdb = true; } ];

  # ── Audiobookshelf ───────────────────────────────────────────────────────
  absEnv = config: config.systemd.services.audiobookshelf-bootstrap.environment;

  absMoved = serverWith [
    {
      lanbat.services.audiobookshelf.settings = {
        drive = "a";
        libraryPath = "books/audio";
        metadataProvider = "audible.uk";
      };
    }
  ];

  # ── Redis indexes and Nextcloud's database ───────────────────────────────
  redisClash = serverWith [ { lanbat.redis.databases.other.index = 1; } ];

  envOf = config: container: config.virtualisation.oci-containers.containers.${container}.environment;

  # ── Telegraf ─────────────────────────────────────────────────────────────
  telegrafConf = config: config.services.telegraf.extraConfig;
  healthChecks =
    config: map (c: "${c.name_override} ${lib.head c.urls}") (telegrafConf config).inputs.http_response;

  telegrafChanged = serverWith [
    {
      lanbat.services = {
        influxdb.endpoint.port = lib.mkForce 18086;
        grafana.port = lib.mkForce 13030;
        telegraf.settings.pingTargets = [ "192.0.2.1" ];
      };
      services.redis.servers.shared.port = lib.mkForce 16379;
    }
  ];

  # ── RomM ─────────────────────────────────────────────────────────────────
  rommVolumes = config: config.virtualisation.oci-containers.containers.romm.volumes;

  rommMoved = serverWith [
    {
      lanbat.services.romm.settings = {
        drive = "a";
        libraryPath = "games/roms";
        browserArcadePath = "games/arcade";
        authentikAdmin = "alice";
      };
    }
  ];

  # ── Music Assistant ──────────────────────────────────────────────────────
  maScript = config: config.systemd.services.music-assistant-setup.script;

  maMoved = serverWith [
    {
      lanbat.services = {
        music-assistant.port = lib.mkForce 18095;
        home-assistant = {
          port = lib.mkForce 18123;
          subdomain = lib.mkForce "hass";
        };
      };
    }
  ];

  # ── Snapcast ─────────────────────────────────────────────────────────────
  fwStart = config: config.networking.firewall.extraCommands;
  fwStop = config: config.networking.firewall.extraStopCommands;
  admits =
    address: config:
    lib.all
      (
        port: lib.hasInfix "INPUT -p tcp --dport ${toString port} -s ${address} -j ACCEPT" (fwStart config)
      )
      [
        1704
        1705
      ];
  snapClients = serverWith [
    { lanbat.services.snapcast.settings.clients.phone.host = "192.0.2.70"; }
  ];
  snapBadHost = serverWith [
    { lanbat.services.snapcast.settings.clients.phone.host = "phone.lan"; }
  ];
  snapDuplicate = serverWith [
    {
      lanbat.services.snapcast.settings.clients = {
        phone.host = "192.0.2.70";
        tablet.host = "192.0.2.70";
      };
    }
  ];
  snapMac = serverWith [
    { lanbat.services.snapcast.settings.clients.tv.mac = "2c:d8:ae:00:00:01"; }
  ];
  snapEmpty = serverWith [ { lanbat.services.snapcast.settings.clients.tv = { }; } ];
  snapBadMac = serverWith [ { lanbat.services.snapcast.settings.clients.tv.mac = "2c-d8-ae"; } ];
  # Music Assistant placed on a host without the snapserver.
  maApart = serverWith [ { lanbat.endpoints.snapcast.hosts = lib.mkForce [ "pi-storage" ]; } ];

  # ── Immich ───────────────────────────────────────────────────────────────
  immichMoved = serverWith [
    {
      lanbat.services.immich = {
        port = lib.mkForce 12283;
        settings = {
          drive = "b";
          uploadPath = "media/photos";
        };
      };
      services.redis.servers.shared.port = lib.mkForce 16379;
    }
  ];
  immichUpload =
    config: lib.head config.virtualisation.oci-containers.containers.immich-server.volumes;

  # ── Nextcloud ────────────────────────────────────────────────────────────
  nextcloudMoved = serverWith [
    {
      lanbat.services.nextcloud.settings.storage = {
        drive = "a";
        path = "cloud";
      };
    }
  ];
  nextcloudDirs =
    config: lib.filter (lib.hasInfix " nextcloud nextcloud ") config.systemd.tmpfiles.rules;

  expect = name: ok: if ok then null else name;

  cases = [
    (expect "samba: the default layout renders today's shares" (
      smb base == {
        global = (smb base).global;
        homes = {
          comment = "Home Directories";
          browseable = "no";
          "read only" = "no";
          "create mask" = "0700";
          "directory mask" = "0700";
          "valid users" = "%S";
          path = "/srv/storage/b/users/%S/files";
        };
        media = {
          comment = "Media: movies, TV, music videos";
          path = "/srv/storage/a/media";
          browseable = "yes";
          "read only" = "yes";
          "guest ok" = "no";
          "valid users" = "@media";
        };
        media-b = {
          comment = "Media: music, documentaries, books, ROMs";
          path = "/srv/storage/b/media";
          browseable = "yes";
          "read only" = "yes";
          "guest ok" = "no";
          "valid users" = "@media";
          "veto files" = "/adult/";
        };
        private = {
          comment = "Private";
          path = "/srv/storage/b/media/adult";
          browseable = "no";
          "read only" = "yes";
          "guest ok" = "no";
          "valid users" = "@private";
        };
        shared = {
          comment = "Shared";
          path = "/srv/storage/b/shared";
          browseable = "yes";
          "read only" = "no";
          "guest ok" = "no";
          "valid users" = "@media";
          "create mask" = "0664";
          "directory mask" = "0775";
          "force group" = "media";
        };
      }
      && (smb base).global.workgroup == "WORKGROUP"
      && (smb base).global."netbios name" == "server"
      &&
        sambaDrives base == [
          "a"
          "b"
        ]
      && lib.elem "d /srv/storage/b/shared 0775 root media -" base.systemd.tmpfiles.rules
    ))

    (expect "samba: a profile adds, changes and drops shares field by field" (
      let
        s = smb sambaChanged;
      in
      s.global.workgroup == "LAB"
      && !(s ? private)
      && s.media-b."veto files" == "/adult/tmp/"
      && s.media-b.comment == "Media: music, documentaries, books, ROMs"
      &&
        s.scans == {
          comment = "";
          path = "/srv/storage/a/scans";
          browseable = "yes";
          "read only" = "no";
          "guest ok" = "no";
          "valid users" = "@media";
          "hide dot files" = "yes";
        }
      && lib.elem "d /srv/storage/b/shared 0770 root media -" sambaChanged.systemd.tmpfiles.rules
    ))

    (expect "samba: smbd binds to the drives its shares use" (
      sambaDrives sambaDriveA == [ "a" ]
      && !((smb sambaDriveA) ? homes)
      &&
        lib.attrNames (smb sambaDriveA) == [
          "global"
          "media"
        ]
    ))

    (expect "samba: an unknown settings key is rejected" (
      lib.any (lib.hasInfix "samba has no setting \"share\"") (failedAssertions sambaTypo)
    ))

    (expect "wyoming: the defaults keep today's pipeline and satellite" (
      let
        w = base.services.wyoming;
        sat = base.lanbat.voiceSatellite;
      in
      w.openwakeword.threshold == toString 0.35
      && w.faster-whisper.servers.main.model == "base-int8"
      && w.faster-whisper.servers.main.language == "en"
      && w.piper.servers.main.voice == "en_GB-alan-medium"
      && sat.name == "Server Satellite"
      && sat.speaker == "plughw:CARD=PCH,DEV=0"
      && sat.mixer == [ "-c PCH sset Master 80% unmute" ]
      && sat.microphone.usbId == "1415:2000"
    ))

    (expect "wyoming: a profile's settings reach the servers, satellite and pipeline" (
      let
        w = wyomingChanged.services.wyoming;
        sat = wyomingChanged.lanbat.voiceSatellite;
      in
      w.openwakeword.threshold == toString 0.5
      && w.faster-whisper.servers.main.model == "small-int8"
      && w.piper.servers.main.voice == "de_DE-thorsten-medium"
      && sat.name == "Office Satellite"
      && sat.speaker == "plughw:CARD=Generic,DEV=0"
      && sat.mixer == [ ]
      && sat.microphone.usbId == "046d:0825"
      && lib.hasInfix ''PIPELINE_STT_LANGUAGE="de"'' (postSetup wyomingChanged)
      && lib.hasInfix ''PIPELINE_TTS_LANGUAGE="de_DE"'' (postSetup wyomingChanged)
    ))

    (expect "wyoming: a voice without a language prefix is rejected" (
      !(builtins.tryEval (
        builtins.deepSeq wyomingBadVoice.services.wyoming.piper.servers.main.voice true
      )).success
    ))

    (expect "home assistant: the defaults keep today's URLs and Zigbee watch" (
      (haConfig base).homeassistant.internal_url == "http://127.0.0.1:8123"
      && lib.hasInfix ''export FRIGATE_URL="http://127.0.0.1:5000/"'' (postSetup base)
      && lib.hasInfix ''export MUSIC_ASSISTANT_URL="http://127.0.0.1:8095"'' (postSetup base)
      && lib.hasInfix ''export MQTT_PORT="1883"'' (postSetup base)
      && base.lanbat.voiceSatellite.homeAssistant.url == "http://127.0.0.1:8123"
      &&
        map (a: a.id) (haConfig base).automation == [
          "lanbat_zigbee_bridge_offline"
          "lanbat_zigbee_bridge_online"
        ]
      &&
        haViews base == [
          "home"
          "all"
        ]
    ))

    (expect "home assistant: the URLs follow the services' descriptions" (
      (haConfig haMoved).homeassistant.internal_url == "http://127.0.0.1:18123"
      && lib.hasInfix ''export INTERNAL_URL="http://127.0.0.1:18123"'' haMoved.systemd.services.home-assistant-bootstrap.script
      && lib.hasInfix ''export FRIGATE_URL="http://127.0.0.1:15000/"'' (postSetup haMoved)
      && lib.hasInfix ''export MUSIC_ASSISTANT_URL="http://127.0.0.1:18095"'' (postSetup haMoved)
      && lib.hasInfix ''export MQTT_PORT="11883"'' (postSetup haMoved)
      && haMoved.lanbat.voiceSatellite.homeAssistant.url == "http://127.0.0.1:18123"
    ))

    (expect "home assistant: the Zigbee watch can be turned off" (
      (haConfig haNoZigbee).automation == [ ] && haViews haNoZigbee == [ "all" ]
    ))

    (expect "telegraf: the defaults keep today's outputs and inputs" (
      let
        t = telegrafConf base;
      in
      (lib.head t.outputs.influxdb_v2).urls == [ "http://localhost:8086" ]
      &&
        healthChecks base == [
          "grafana http://127.0.0.1:3030/api/health"
          "home-assistant http://127.0.0.1:8123/"
          "jellyfin http://127.0.0.1:8096/health"
          "immich http://127.0.0.1:2283/api/server/ping"
          "vaultwarden http://127.0.0.1:8222/alive"
        ]
      &&
        (lib.head t.inputs.ping).urls == [
          "192.0.2.11"
          "192.0.2.1"
          "1.1.1.1"
        ]
      && (lib.head t.inputs.redis).servers == [ "tcp://127.0.0.1:6379" ]
    ))

    (expect "telegraf: the ports follow the services and the ping targets the profile" (
      let
        t = telegrafConf telegrafChanged;
      in
      (lib.head t.outputs.influxdb_v2).urls == [ "http://localhost:18086" ]
      && lib.head (healthChecks telegrafChanged) == "grafana http://127.0.0.1:13030/api/health"
      && (lib.head t.inputs.ping).urls == [ "192.0.2.1" ]
      && (lib.head t.inputs.redis).servers == [ "tcp://127.0.0.1:16379" ]
    ))

    (expect "romm: the defaults keep today's library on drive b" (
      lib.sublist 3 2 (rommVolumes base) == [
        "/srv/storage/b/media/roms:/romm/library/roms"
        "/srv/storage/b/media/roms-browser/mame:/romm/library/roms/mame"
      ]
      && base.lanbat.services.romm.nfs.drives == [ "b" ]
      && base.lanbat.services.romm.workloadDirs.romm.mode == "0711"
      && base.lanbat.services.romm.workloadDirs."romm/resources".mode == "0711"
      &&
        base.systemd.services.romm-browser-romsets.environment.SOURCE_DIR
        == "/srv/storage/b/media/roms/mame"
      && (envOf base "romm").REDIS_PORT == "6379"
      && (envOf base "romm").OIDC_ALLOW_REGISTRATION == "false"
      && (envOf base "romm").DISABLE_USERPASS_LOGIN == "false"
      && lib.hasSuffix "/api/oauth/openid" (envOf base "romm").OIDC_REDIRECT_URI
      && lib.hasInfix "-v user=akadmin " base.systemd.services.romm-admin-email.script
      && lib.elem "romm-admin-email.service" base.systemd.services.podman-romm.wants
      && lib.elem "romm-admin-email" base.lanbat.services.romm.units
    ))

    (expect "romm: a profile moves the library, and the NFS dependency follows" (
      lib.sublist 3 2 (rommVolumes rommMoved) == [
        "/srv/storage/a/games/roms:/romm/library/roms"
        "/srv/storage/a/games/arcade:/romm/library/roms/mame"
      ]
      && rommMoved.lanbat.services.romm.nfs.drives == [ "a" ]
      &&
        rommMoved.systemd.services.romm-browser-romsets.environment.TARGET_DIR
        == "/srv/storage/a/games/arcade"
      && lib.hasInfix "-v user=alice " rommMoved.systemd.services.romm-admin-email.script
      && failedAssertions rommMoved == [ ]
    ))

    (expect "music-assistant: the setup keeps today's URLs" (
      lib.all (line: lib.hasInfix line (maScript base)) [
        ''export MA_URL="http://127.0.0.1:8095"''
        ''export MA_PUBLIC_URL="https://music.home.example.com"''
        ''export HA_INTERNAL_URL="http://127.0.0.1:8123"''
        ''export HA_PUBLIC_URL="https://ha.home.example.com"''
      ]
    ))

    (expect "music-assistant: the setup follows the services' ports and subdomains" (
      lib.all (line: lib.hasInfix line (maScript maMoved)) [
        ''export MA_URL="http://127.0.0.1:18095"''
        ''export HA_INTERNAL_URL="http://127.0.0.1:18123"''
        ''export HA_PUBLIC_URL="https://hass.home.example.com"''
      ]
    ))

    (expect "immich: the defaults keep today's upload directory and ports" (
      immichUpload base == "/srv/storage/a/photos:/usr/src/app/upload"
      && base.lanbat.services.immich.nfs.drives == [ "a" ]
      && lib.elem "d /srv/storage/a/photos 0750 immich immich -" base.systemd.tmpfiles.rules
      && (envOf base "immich-server").DB_PORT == "5432"
      && (envOf base "immich-server").REDIS_PORT == "6379"
      && lib.hasInfix ''IMMICH_URL="http://127.0.0.1:2283"'' base.systemd.services.immich-bootstrap.script
      && lib.hasInfix ''"https://photos.home.example.com"'' base.systemd.services.podman-immich-server.preStart
    ))

    (expect "immich: a profile moves the uploads, and the ports follow the services" (
      immichUpload immichMoved == "/srv/storage/b/media/photos:/usr/src/app/upload"
      && immichMoved.lanbat.services.immich.nfs.drives == [ "b" ]
      && (envOf immichMoved "immich-server").REDIS_PORT == "16379"
      && lib.hasInfix ''IMMICH_URL="http://127.0.0.1:12283"'' immichMoved.systemd.services.immich-bootstrap.script
      && failedAssertions immichMoved == [ ]
    ))

    (expect "grafana: the InfluxDB datasource follows InfluxDB's endpoint" (
      let
        influxUrl =
          config: (lib.head config.services.grafana.provision.datasources.settings.datasources).url;
      in
      influxUrl base == "http://localhost:8086"
      && influxUrl telegrafChanged == "http://localhost:18086"
      && base.services.grafana.settings.server.root_url == "https://grafana.home.example.com"
    ))

    (expect "nextcloud: the bulk data directories keep today's paths, and move" (
      lib.all (rule: lib.elem rule (nextcloudDirs base)) [
        "d /srv/storage/b/nextcloud          0750 nextcloud nextcloud -"
        "d /srv/storage/b/nextcloud/external 0750 nextcloud nextcloud -"
        "d /srv/storage/b/nextcloud/users    0750 nextcloud nextcloud -"
      ]
      && lib.elem "d /srv/storage/a/cloud/users    0750 nextcloud nextcloud -" (
        nextcloudDirs nextcloudMoved
      )
      && !lib.any (lib.hasPrefix "d /srv/storage/b/nextcloud") (nextcloudDirs nextcloudMoved)
      && nextcloudMoved.lanbat.services.nextcloud.nfs.drives == [ ]
    ))

    (expect "redis: the consumers keep today's indexes" (
      lib.mapAttrs (_: db: db.index) base.lanbat.redis.databases == {
        authentik = 0;
        immich = 1;
        romm = 2;
      }
      && (envOf base "authentik-server").AUTHENTIK_REDIS__DB == "0"
      && (envOf base "immich-server").REDIS_DBINDEX == "1"
      && (envOf base "romm").REDIS_DB == "2"
    ))

    (expect "redis: two consumers claiming one index are rejected" (
      lib.any (lib.hasInfix "index 1 is claimed by immich and other") (failedAssertions redisClash)
    ))

    (expect "nextcloud: the workload instance's nextcloud database, over its socket" (
      let
        nc = base.services.nextcloud;
        pg = base.services.postgresql;
      in
      !nc.database.createLocally
      && nc.config.dbhost == "/run/postgresql"
      && nc.config.dbname == "nextcloud"
      && nc.config.dbuser == "nextcloud"
      && nc.config.dbpassFile == null
      && base.lanbat.postgresql.databases.nextcloud.instance == "workload"
      && lib.elem "nextcloud" pg.ensureDatabases
      && lib.any (u: u.name == "nextcloud" && u.ensureDBOwnership) pg.ensureUsers
      && lib.elem "postgresql.target" base.systemd.services.nextcloud-setup.requires
      && lib.elem "postgresql.target" base.systemd.services.nextcloud-setup.after
    ))

    (expect "jellyfin: IMVDb is off by default and needs no key" (
      !(base.lanbat.secrets ? jellyfin-imvdb-env) && !lib.hasInfix "imvdb" (jellyfinBootstrap base)
    ))

    (expect "jellyfin: settings.imvdb requires the IMVDb key and hands it to the bootstrap" (
      jellyfinImvdb.lanbat.secrets ? jellyfin-imvdb-env
      && lib.hasInfix jellyfinImvdb.lanbat.secrets.jellyfin-imvdb-env.path (
        jellyfinBootstrap jellyfinImvdb
      )
      && failedAssertions jellyfinImvdb == [ ]
    ))

    (expect "audiobookshelf: the library defaults to drive b's audiobooks and Audible" (
      (absEnv base).LIBRARY_PATH == "/srv/storage/b/media/audiobooks"
      && (absEnv base).METADATA_PROVIDER == "audible"
      && base.lanbat.services.audiobookshelf.nfs.drives == [ "b" ]
      && (absEnv base).EXTERNAL_URL == "https://audiobooks.home.example.com"
    ))

    (expect "audiobookshelf: a profile moves the library and picks the provider" (
      (absEnv absMoved).LIBRARY_PATH == "/srv/storage/a/books/audio"
      && (absEnv absMoved).METADATA_PROVIDER == "audible.uk"
      && absMoved.systemd.services.audiobookshelf-match.environment.METADATA_PROVIDER == "audible.uk"
      && absMoved.lanbat.services.audiobookshelf.nfs.drives == [ "a" ]
      && lib.elem "srv-storage-a.mount" absMoved.systemd.services.audiobookshelf.bindsTo
      && failedAssertions absMoved == [ ]
    ))

    (expect "snapcast: its ports are no longer open to the whole LAN" (
      !lib.elem 1704 base.networking.firewall.allowedTCPPorts
      && !lib.elem 1705 base.networking.firewall.allowedTCPPorts
    ))

    (expect "snapcast: the Pi's snapclient and the Snapdroid box are admitted on both ports" (
      admits "192.0.2.11" base && admits "192.0.2.50" base
    ))

    (expect "snapcast: a listed client is admitted, and its rules are removed on stop" (
      admits "192.0.2.70" snapClients
      && lib.hasInfix "iptables -D INPUT -p tcp --dport 1705 -s 192.0.2.70 -j ACCEPT" (fwStop snapClients)
      && !lib.hasInfix "192.0.2.70" (fwStart base)
    ))

    (expect "snapcast: a client listed by MAC is admitted over IPv4 and IPv6, and removed on stop" (
      lib.all
        (
          cmd:
          lib.all
            (
              port:
              lib.hasInfix "${cmd} -I INPUT -p tcp --dport ${toString port} -m mac --mac-source 2c:d8:ae:00:00:01 -j ACCEPT" (
                fwStart snapMac
              )
              && lib.hasInfix "${cmd} -D INPUT -p tcp --dport ${toString port} -m mac --mac-source 2c:d8:ae:00:00:01 -j ACCEPT" (
                fwStop snapMac
              )
            )
            [
              1704
              1705
            ]
        )
        [
          "iptables"
          "ip6tables"
        ]
    ))

    (expect "snapcast: a client needs a MAC or an IPv4 address, and a well-formed MAC" (
      lib.any (lib.hasInfix "client tv") (failedAssertions snapEmpty)
      && lib.any (lib.hasInfix "2c-d8-ae") (failedAssertions snapBadMac)
    ))

    (expect "snapcast: a client must be an IPv4 address" (
      lib.any (lib.hasInfix "phone.lan") (failedAssertions snapBadHost)
    ))

    (expect "snapcast: two clients can't share an address" (
      lib.any (lib.hasInfix "192.0.2.70") (failedAssertions snapDuplicate)
    ))

    (expect "music-assistant: a snapserver on another host is rejected" (
      lib.any (lib.hasInfix "#117") (failedAssertions maApart)
    ))

    (expect "the example profile's server has no failed assertion" (failedAssertions base == [ ]))
  ];

  failures = lib.filter (x: x != null) cases;
in
pkgs.runCommand "service-settings-check" { } ''
  if [ ${toString (lib.length failures)} -ne 0 ]; then
    echo "service settings checks failed:" >&2
    ${lib.concatStringsSep "\n" (map (msg: "echo \"  - ${msg}\" >&2") failures)}
    exit 1
  fi
  touch $out
''

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

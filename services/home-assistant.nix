# services/home-assistant.nix
#
# Home Assistant — home automation hub.
#
# Why the NixOS module and not a container?
#   The NixOS `services.home-assistant` module handles component packaging,
#   config dir, user/group, and service lifecycle very cleanly.
#   It is significantly easier to maintain than a container for HA specifically
#   because NixOS can manage the Python component set declaratively.
#
# Zigbee
# ------
# Zigbee devices are bridged via Zigbee2MQTT (see zigbee2mqtt.nix).
# Z2M owns the USB dongle and publishes to Mosquitto; HA discovers devices
# via MQTT auto-discovery.  Do NOT add ZHA here — it would conflict with Z2M.
#
# Auth with Authentik
# -------------------
# Browser access is gated by Caddy forward-auth (Authentik session).  The
# hass-auth-header custom component maps X-Authentik-Username to an existing HA
# user, so entitled Authentik users land in HA without a second login.
#
# Companion apps and REST clients bypass forward-auth on /auth/token and /api/*
# and authenticate with HA long-lived tokens as usual.
#
# First-run onboarding is completed automatically by home-assistant-bootstrap
# (owner account + SSO user mirror).  Break-glass local login remains available
# on localhost.
#
# Voice
# -----
# home-assistant-post-setup adds the Wyoming services and satellites
# (services/wyoming.nix) and makes a "Voice" pipeline the preferred one:
# openWakeWord, faster-whisper, piper, and as the conversation agent the LLM
# in lanbat.haLlm, or Home Assistant's own agent without one. Local intents
# are tried first, so simple commands don't wait for the LLM.
#
# Always-on: yes — HA should survive Pi NFS loss.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  domain = config.lanbat.deployment.domain;
  authHeaderComponent = pkgs.callPackage ../pkgs/home-assistant-auth-header { };
  bootstrap = pkgs.callPackage ../pkgs/home-assistant-bootstrap { };
  postSetup = pkgs.callPackage ../pkgs/home-assistant-post-setup { };
  llm = config.lanbat.deployment.haLlm;
  llmComponent = pkgs.callPackage ../pkgs/home-assistant-extended-openai-conversation { };
  satellite = config.lanbat.voiceSatellite;
  piper = config.services.wyoming.piper.servers.main;
  # A satellite with a room hands its replies to the voice_reply script.
  voiceRooms = config.lanbat.deployment.voiceRooms != { };
in
{
  options.lanbat.homeAssistant = {
    ssoUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "akadmin" ];
      description = ''
        Authentik usernames to provision as Home Assistant users.  Login is via
        header auth (no password); usernames must match Authentik exactly.
      '';
    };
  };

  config = {
    lanbat.services.home-assistant = {
      subdomain = "ha";
      port = 8123;
      auth = "forward-auth";
      apiClients = true; # companion apps — /auth/token and /api/* bypass forward-auth
      secrets = {
        hass-bootstrap-env.owner = "hass";
      }
      // lib.optionalAttrs (llm != null) {
        # The API key of the conversation agent's LLM.
        ha-llm-api-key.owner = "hass";
      }
      // lib.optionalAttrs voiceRooms {
        # The record of the voice satellites' token, for home-assistant-post-setup.
        ha-voice-refresh-token.owner = "root";
      };
      caddy.proxyOptions = ''
        # Long-lived websockets for HA's live updates.
        transport http {
          keepalive 24h
        }
      '';
      dashboard = {
        group = "Automation";
        name = "Home Assistant";
        description = "Home automation";
        widget = {
          type = "homeassistant";
          key = {
            _secret = "HA_LONG_LIVED_TOKEN";
          };
        };
      };
    };

    # The recorder (history) lives in the always-on PostgreSQL. HA logs in as
    # its system user over the socket, so no password is needed.
    lanbat.postgresql.databases.hass.instance = "always-on";

    systemd.services.home-assistant = {
      after = [
        (config.lanbat.postgresql.instance "always-on").unit
        "mosquitto.service"
      ];
      requires = [
        (config.lanbat.postgresql.instance "always-on").unit
        "mosquitto.service"
      ];
    };

    systemd.services.home-assistant-bootstrap = {
      description = "Complete Home Assistant onboarding and provision SSO users";
      wantedBy = [ "multi-user.target" ];
      after = [ "home-assistant.service" ];
      wants = [ "home-assistant.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "hass";
        Group = "hass";
        EnvironmentFile = config.age.secrets.hass-bootstrap-env.path;
      };

      path = [ bootstrap ];

      script = ''
        set -a
        . ${config.age.secrets.hass-bootstrap-env.path}
        set +a
        export INTERNAL_URL="http://127.0.0.1:8123"
        export EXTERNAL_URL="https://ha.${domain}"
        export SSO_USERS="${lib.concatStringsSep " " config.lanbat.homeAssistant.ssoUsers}"
        exec home-assistant-bootstrap
      '';
    };

    systemd.services.home-assistant-post-setup = {
      description = "Configure Home Assistant integrations (MQTT, Frigate, Wyoming, Music Assistant, voice)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "home-assistant.service"
        "home-assistant-bootstrap.service"
        "music-assistant-setup.service"
        "mosquitto.service"
      ];
      wants = [ "music-assistant-setup.service" ];
      requires = [ "mosquitto.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
      };

      path = [ postSetup ];

      script = ''
        ${lib.optionalString (config.lanbat.hasService "mosquitto") ''
          export MQTT_BROKER="127.0.0.1"
          export MQTT_PORT="1883"
          export MQTT_USERNAME="homeassistant"
          export MQTT_PASSWORD="$(cat ${config.age.secrets.mosquitto-ha-pass.path})"
        ''}
        export FRIGATE_URL="http://127.0.0.1:5000/"
        export MUSIC_ASSISTANT_URL="http://127.0.0.1:8095"
        export PI_HOST="${config.lanbat.deployment.storageIp}"
        ${lib.optionalString satellite.enable ''
          export LOCAL_SATELLITE_PORT="${lib.last (lib.splitString ":" satellite.uri)}"
        ''}
        export PIPELINE_STT_LANGUAGE="${config.services.wyoming.faster-whisper.servers.main.language}"
        export PIPELINE_TTS_LANGUAGE="${lib.head (lib.splitString "-" piper.voice)}"
        export PIPELINE_TTS_VOICE="${piper.voice}"
        export PIPELINE_WAKE_WORD="hey_nabu"
        ${lib.optionalString (llm != null) ''
          export LLM_BASE_URL="${llm.baseUrl}"
          export LLM_MODEL="${llm.model}"
          export LLM_API_KEY_FILE="${config.age.secrets.ha-llm-api-key.path}"
          export LLM_MAX_TOKENS="150"
          export LLM_USE_TOOLS="false"
        ''}
        ${lib.optionalString voiceRooms ''
          export VOICE_TOKEN_RECORD_FILE="${config.age.secrets.ha-voice-refresh-token.path}"
        ''}
        exec home-assistant-post-setup
      '';
    };

    services.home-assistant = {
      enable = true;
      openFirewall = false; # Caddy handles exposure.

      # PostgreSQL driver for the recorder.
      extraPackages = ps: [ ps.psycopg2 ];

      # Install extra Python components declaratively.
      customComponents = [
        # 2 upstream test failures in nixpkgs 26.05 packaging; skip checks.
        (pkgs.home-assistant-custom-components.frigate.overridePythonAttrs (_: {
          doCheck = false;
        }))
        (authHeaderComponent.overridePythonAttrs (_: {
          doCheck = false;
        }))
      ]
      # The conversation agent for the LLM in lanbat.haLlm.
      ++ lib.optional (llm != null) llmComponent;

      extraComponents = [
        "default_config"
        "met" # weather
        "radio_browser"
        "google_translate" # TTS — gtts dependency
        "mqtt" # Zigbee devices arrive via Zigbee2MQTT → MQTT discovery
        "mobile_app"
        "person"
        "history"
        "logbook"
        "recorder"
        "frontend"
        "config"
        "lovelace"
        "network"
        "stream"
        "camera"
        "ffmpeg"
        # Wyoming voice assistant protocol
        "wyoming"
        "music_assistant"
        "qbittorrent"
      ]
      # extended_openai_conversation depends on these.
      ++ lib.optionals (llm != null) [
        "rest"
        "scrape"
      ];

      config = {
        # Trust Caddy as reverse proxy.
        http = {
          use_x_forwarded_for = true;
          trusted_proxies = [
            "127.0.0.1"
            "::1"
          ];
          ip_ban_enabled = true;
          login_attempts_threshold = 5;
        };

        homeassistant = {
          name = "Home";
          latitude = config.lanbat.deployment.haLatitude;
          longitude = config.lanbat.deployment.haLongitude;
          elevation = config.lanbat.deployment.haElevation;
          unit_system = "metric";
          time_zone = config.lanbat.deployment.timezone;
          external_url = "https://ha.${domain}";
          # Music Assistant fetches tts_proxy URLs server-side; use loopback so
          # announcements are not blocked by ip_ban when MA calls 192.168.1.10.
          internal_url = "http://127.0.0.1:8123";
        };

        # Voice replies in a room (modules/core/voice-satellite.nix). A satellite
        # with a room calls voice_reply with its reply; voice_reply starts the
        # announcement on the room's Music Assistant players and returns how
        # many there are, so the satellite knows whether to play it itself.
        script = {
          voice_reply = {
            alias = "Voice reply in a room";
            mode = "parallel";
            fields = {
              message.description = "The reply to speak.";
              room.description = "Name of the area the voice satellite is in.";
            };
            sequence = [
              {
                variables.players = "{{ area_entities(room) | select('in', integration_entities('music_assistant')) | select('match', 'media_player[.]') | reject('is_state', ['unavailable', 'unknown']) | list }}";
              }
              {
                "if" = "{{ players | count > 0 }}";
                "then" = [
                  {
                    action = "script.turn_on";
                    target.entity_id = "script.voice_reply_announce";
                    data.variables = {
                      players = "{{ players }}";
                      message = "{{ message }}";
                    };
                  }
                ];
              }
              { variables.result.players = "{{ players | count }}"; }
              {
                stop = "Reply handed to the room";
                response_variable = "result";
              }
            ];
          };

          voice_reply_announce = {
            alias = "Voice reply announcement";
            mode = "queued";
            fields = {
              players.description = "Music Assistant players to announce on.";
              message.description = "The reply to speak.";
            };
            sequence = [
              {
                # An announcement: Music Assistant turns the music down meanwhile.
                action = "tts.speak";
                target.entity_id = "tts.piper";
                data = {
                  media_player_entity_id = "{{ players }}";
                  message = "{{ message }}";
                  language = lib.head (lib.splitString "-" piper.voice);
                  options.voice = piper.voice;
                };
              }
            ];
          };
        };

        # Authentik forward-auth → header-based login (users must exist in HA).
        auth_header = {
          username_header = "X-Authentik-Username";
        };

        # Recorder — keep 30 days in the always-on PostgreSQL.
        recorder = {
          purge_keep_days = 30;
          db_url =
            let
              pg = (config.lanbat.postgresql.instance "always-on");
            in
            "postgresql://@/hass?host=${pg.socket}&port=${toString pg.port}";
          exclude = {
            entity_globs = [
              "*.linkquality"
              "*.rssi"
              "select.*switch_type"
            ];
          };
        };

        automation = [
          {
            alias = "Zigbee bridge offline";
            id = "lanbat_zigbee_bridge_offline";
            trigger = [
              {
                platform = "state";
                entity_id = "binary_sensor.zigbee2mqtt_bridge_connection_state";
                to = "off";
              }
            ];
            action = [
              {
                service = "persistent_notification.create";
                data = {
                  notification_id = "zigbee_bridge_offline";
                  title = "Zigbee bridge offline";
                  message = "Zigbee2MQTT lost its MQTT connection.";
                };
              }
            ];
          }
          {
            alias = "Zigbee bridge online";
            id = "lanbat_zigbee_bridge_online";
            trigger = [
              {
                platform = "state";
                entity_id = "binary_sensor.zigbee2mqtt_bridge_connection_state";
                to = "on";
              }
            ];
            action = [
              {
                service = "persistent_notification.dismiss";
                data.notification_id = "zigbee_bridge_offline";
              }
            ];
          }
        ];
      };

      lovelaceConfig = {
        title = "Home";
        views = [
          {
            title = "Overview";
            path = "home";
            cards = [
              {
                type = "entities";
                title = "Zigbee bridge";
                entities = [
                  "switch.zigbee2mqtt_bridge_permit_join"
                  "binary_sensor.zigbee2mqtt_bridge_connection_state"
                  "binary_sensor.zigbee2mqtt_bridge_restart_required"
                ];
              }
              {
                type = "entity-filter";
                show_empty = false;
                filters = [
                  {
                    domain = "switch";
                    options = {
                      exclude = "switch.zigbee2mqtt_bridge_permit_join";
                    };
                  }
                ];
                card = {
                  type = "entities";
                  title = "Switches";
                };
              }
            ];
          }
        ];
      };
    };

    systemd.services.runpod-ha-llm-keepalive = lib.mkIf (llm != null) {
      description = "Ping RunPod HA LLM to avoid scale-to-zero cold starts";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      path = [
        pkgs.curl
        pkgs.coreutils
      ];
      script = ''
        key=$(cat ${config.age.secrets.ha-llm-api-key.path})
        curl -sS --max-time 45 \
          -H "Authorization: Bearer $key" \
          -H "Content-Type: application/json" \
          -d '{"model":"${llm.model}","messages":[{"role":"user","content":"ping"}],"max_tokens":1,"chat_template_kwargs":{"enable_thinking":false}}' \
          "${llm.baseUrl}/chat/completions" >/dev/null || true
      '';
    };

    systemd.timers.runpod-ha-llm-keepalive = lib.mkIf (llm != null) {
      description = "Keep RunPod HA LLM worker warm between voice commands";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "4min";
        AccuracySec = "1min";
      };
    };

    # HA state lives entirely on server-local storage — resilient to Pi loss.
    # /var/lib/hass is managed by the NixOS module.
  };
}

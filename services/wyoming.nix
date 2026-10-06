# services/wyoming.nix
#
# Wyoming voice assistant pipeline — server-side services.
#
# Wyoming is Home Assistant's open voice assistant protocol.
# These three services form the processing pipeline that HA uses
# when a satellite (this server's own, or the Pi's) captures speech:
#
#   mic → satellite → HA → openwakeword → faster-whisper → conversation agent
#                                                                ↓
#            speaker ← satellite ← HA ← piper (TTS) ←───────────┘
#
# The conversation agent tries Home Assistant's local intents first, then the
# LLM in lanbat.haLlm (services/home-assistant.nix).
#
# Everything here listens on 127.0.0.1 only — HA connects to it locally.  No
# server firewall changes are needed.  The only external connection is HA
# (server) → the Pi's satellite on port 10700, which is outbound.
#
# Services
# --------
# openwakeword (10300) — detects the wake word ("hey nabu", custom model).
#   The model file must be named hey_nabu.tflite (see pkgs/hey-nabu-wakeword-model).
#   Bundled alternatives: okay_nabu, hey_jarvis, hey_mycroft, alexa.
#
# faster-whisper (10301) — speech-to-text.
#   Downloads the model on first start (~40 MB for base-int8).
#   base-int8 is the voice default: noticeably faster than small-int8 on CPU
#   with enough accuracy for short commands. Use small-int8 if transcripts
#   are often wrong.
#
# piper (10302) — text-to-speech.
#   Downloads the voice model on first start (~60 MB).
#   The default voice, "en_GB-alan-medium", is a natural-sounding British
#   English male voice.  See https://rhasspy.github.io/piper-samples/ for
#   all available voices.
#
# satellite (10700) — this server's microphone and speaker
#   (modules/core/voice-satellite.nix).
#
# Settings
# --------
# The wake word threshold, the speech-to-text model and language, the piper
# voice and the server satellite's name, speaker, mixer and microphone are
# lanbat.services.wyoming.settings (options below). The defaults are the
# British English pipeline above and the onboard Intel codec (ALSA card PCH);
# a profile changes them from a module in the host's modules
# (docs/extensibility.md#service-settings):
#
#   lanbat.services.wyoming.settings = {
#     speechToText.language = "de";
#     textToSpeech.voice = "de_DE-thorsten-medium";
#     satellite.speaker = "plughw:CARD=Generic,DEV=0";
#     satellite.mixer = [ "-c Generic sset Master 80% unmute" ];
#   };
#
# HA setup
# --------
# home-assistant-post-setup adds these services and both satellites to HA,
# and makes a "Voice" pipeline using them the preferred one.
# See docs/deployment-checklist.md § Wyoming voice assistant.
#
# Always-on: yes — no NFS dependency.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  inherit (lib) mkOption types;

  cfg = config.lanbat.services.wyoming.settings;

  wyomingSettings = {
    options = {
      wakeWord.threshold = mkOption {
        type = types.numbers.between 0 1;
        default = 0.35;
        description = "openWakeWord's activation threshold: lower wakes more readily, and falsely more often.";
      };

      speechToText = {
        model = mkOption {
          type = types.str;
          default = "base-int8";
          example = "small-int8";
          description = "faster-whisper model. base-int8 is fast on a CPU; small-int8 transcribes better.";
        };
        language = mkOption {
          type = types.str;
          default = "en";
          description = "Language faster-whisper transcribes, and the pipeline's speech-to-text language.";
        };
      };

      textToSpeech.voice = mkOption {
        type = types.strMatching "[a-z]{2,3}_[A-Za-z]+-.+";
        default = "en_GB-alan-medium";
        description = ''
          piper voice (https://rhasspy.github.io/piper-samples/). Its language
          prefix, before the first "-", is the pipeline's text-to-speech language.
        '';
      };

      satellite = {
        name = mkOption {
          type = types.str;
          default = "Server Satellite";
          description = "Name of the server satellite's device in Home Assistant.";
        };
        speaker = mkOption {
          type = types.str;
          default = "plughw:CARD=PCH,DEV=0";
          description = "ALSA device the server satellite plays replies on (aplay -L lists them). The default is the onboard Intel codec's analog output.";
        };
        mixer = mkOption {
          type = types.listOf types.str;
          default = [ "-c PCH sset Master 80% unmute" ];
          description = "amixer arguments applied before the satellite starts. The default unmutes the onboard codec, whose Master control starts muted.";
        };
        microphoneUsbId = mkOption {
          type = types.nullOr (types.strMatching "[0-9a-f]{4}:[0-9a-f]{4}");
          default = null;
          example = "1415:2000";
          description = "USB vendor:product ID of the microphone. Null keeps the satellite's default, the PlayStation Eye.";
        };
      };
    };
  };

  hostLib = import ../lib/host.nix { inherit lib; };
  serverKey = config.lanbat.deployment.primaryServer;
  serverSatellite =
    serverKey != null && lib.elem serverKey (lib.attrValues config.lanbat.deployment.voiceRooms);
  serverRoom = hostLib.voiceRoomForHost config.lanbat.deployment.voiceRooms serverKey;
  heyNabuModel = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/fwartner/home-assistant-wakewords-collection/main/en/hey_nabu/hey_nabu_v2.tflite";
    hash = "sha256-zhi2nhvd+1bnD+c51soPQj9wpucQ8Fs3a69qNiVokjQ=";
  };
in
{
  # The schema is merged into lanbat.services.wyoming.settings; checks.nix
  # rejects any key it does not declare.
  lanbat.settingsSchema.wyoming = wyomingSettings;

  lanbat.services.wyoming.extraPorts = [
    10300
    10301
    10302
  ]
  ++ lib.optionals config.lanbat.voiceSatellite.enable [ 10700 ];

  # ---------------------------------------------------------------------------
  # Wake word detection
  # ---------------------------------------------------------------------------
  services.wyoming.openwakeword = {
    enable = true;
    uri = "tcp://127.0.0.1:10300";
    inherit (cfg.wakeWord) threshold;
    # preloadModels was removed in wyoming-openwakeword 2.0 — models load when
    # HA requests them, but only from dirs passed via --custom-model-dir.
    extraArgs = [
      "--custom-model-dir"
      "/var/lib/openwakeword/custom-models"
      "--debug"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/openwakeword/custom-models 0755 root root -"
    "L+ /var/lib/openwakeword/custom-models/hey_nabu.tflite - - - - ${heyNabuModel}"
  ];

  # ---------------------------------------------------------------------------
  # Speech-to-text
  # ---------------------------------------------------------------------------
  services.wyoming.faster-whisper.servers."main" = {
    enable = true;
    uri = "tcp://127.0.0.1:10301";
    inherit (cfg.speechToText) model language;
    device = "cpu";
  };

  # ---------------------------------------------------------------------------
  # Text-to-speech
  # ---------------------------------------------------------------------------
  services.wyoming.piper.servers."main" = {
    enable = true;
    uri = "tcp://127.0.0.1:10302";
    inherit (cfg.textToSpeech) voice;
  };

  # ---------------------------------------------------------------------------
  # Satellite: the server's microphone, replies on its speaker (settings.satellite)
  # ---------------------------------------------------------------------------
  #
  # A server in a lanbat.voiceRooms room runs one. Any other server turns it on
  # with `lanbat.voiceSatellite.enable = true;` in its modules: the satellite
  # then starts without the microphone and listens once it is plugged in. The
  # switch can't be a setting here, because the settings are part of
  # lanbat.services, which depends on whether the satellite is enabled.
  lanbat.voiceSatellite = {
    enable = lib.mkIf serverSatellite true;
    inherit (cfg.satellite) name speaker mixer;
    microphone = lib.mkIf (cfg.satellite.microphoneUsbId != null) {
      usbId = cfg.satellite.microphoneUsbId;
    };
    uri = "tcp://127.0.0.1:10700";
    room = serverRoom;
    # The same wake chime as the Pis'.
    awakeSound = lib.mkDefault "${pkgs.callPackage ../pkgs/voice-satellite-awake-chime { }}/awake.wav";
    # Home Assistant on this host's loopback, at the port its description
    # gives; 8123 when it runs elsewhere, as before.
    homeAssistant.url =
      if config.lanbat.hasService "home-assistant" then
        "http://127.0.0.1:${toString config.lanbat.services.home-assistant.port}"
      else
        "http://127.0.0.1:8123";
  };
}

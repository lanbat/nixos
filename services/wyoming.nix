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
# piper (10302) — text-to-speech (British English).
#   Downloads the voice model on first start (~60 MB).
#   Voice "en_GB-alan-medium" is a natural-sounding British English
#   male voice.  See https://rhasspy.github.io/piper-samples/ for
#   all available voices.
#
# satellite (10700) — this server's microphone and speaker
#   (modules/core/voice-satellite.nix).
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
  serverSatellite = config.lanbat.voiceSatelliteServer;
  heyNabuModel = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/fwartner/home-assistant-wakewords-collection/main/en/hey_nabu/hey_nabu_v2.tflite";
    hash = "sha256-zhi2nhvd+1bnD+c51soPQj9wpucQ8Fs3a69qNiVokjQ=";
  };
in
{
  lanbat.services.wyoming.extraPorts = [
    10300
    10301
    10302
  ]
  ++ lib.optionals serverSatellite [ 10700 ];

  # ---------------------------------------------------------------------------
  # Wake word detection
  # ---------------------------------------------------------------------------
  services.wyoming.openwakeword = {
    enable = true;
    uri = "tcp://127.0.0.1:10300";
    threshold = 0.35;
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
    model = "base-int8"; # faster CPU STT for voice commands
    language = "en";
    device = "cpu";
  };

  # ---------------------------------------------------------------------------
  # Text-to-speech  (British English)
  # ---------------------------------------------------------------------------
  services.wyoming.piper.servers."main" = {
    enable = true;
    uri = "tcp://127.0.0.1:10302";
    voice = "en_GB-alan-medium"; # see https://rhasspy.github.io/piper-samples/
  };

  # ---------------------------------------------------------------------------
  # Satellite: the PlayStation Eye's microphones, replies on the internal speaker
  # ---------------------------------------------------------------------------
  lanbat.voiceSatellite = lib.mkIf serverSatellite {
    enable = true;
    name = "Server Satellite";
    uri = "tcp://127.0.0.1:10700";
    # The onboard codec's analog output, which drives the internal speaker.
    speaker = "plughw:CARD=PCH,DEV=0";
    # The codec's Master control starts muted.
    mixer = [ "-c PCH sset Master 80% unmute" ];
    room = config.lanbat.voiceRooms.server;
    homeAssistant.url = "http://127.0.0.1:8123";
  };
}

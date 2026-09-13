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
# openwakeword (10300) — detects the wake word ("okay nabu", model okay_nabu).
#   Uses bundled models; no download needed.
#   Alternative wake words: hey_jarvis, hey_mycroft, alexa.
#
# faster-whisper (10301) — speech-to-text.
#   Downloads the model on first start (~100 MB for small-int8).
#   "small-int8" is a good CPU trade-off; use "base-int8" if the
#   server is slow to respond, or "medium-int8" for higher accuracy.
#
# piper (10302) — text-to-speech (British English).
#   Downloads the voice model on first start (~60 MB).
#   Voice "en_GB-alba-medium" is a natural-sounding British English
#   female voice.  See https://rhasspy.github.io/piper-samples/ for
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

{
  lanbat.services.wyoming.extraPorts = [
    10300
    10301
    10302
    10700 # satellite
  ];

  # ---------------------------------------------------------------------------
  # Wake word detection
  # ---------------------------------------------------------------------------
  services.wyoming.openwakeword = {
    enable = true;
    uri = "tcp://127.0.0.1:10300";
    # preloadModels was removed in wyoming-openwakeword 2.0 — models are now
    # loaded on demand when a wake-word detection request arrives.
  };

  # ---------------------------------------------------------------------------
  # Speech-to-text
  # ---------------------------------------------------------------------------
  services.wyoming.faster-whisper.servers."main" = {
    enable = true;
    uri = "tcp://127.0.0.1:10301";
    model = "small-int8"; # ~100 MB; good CPU accuracy/speed balance
    language = "en";
    device = "cpu";
  };

  # ---------------------------------------------------------------------------
  # Text-to-speech  (British English)
  # ---------------------------------------------------------------------------
  services.wyoming.piper.servers."main" = {
    enable = true;
    uri = "tcp://127.0.0.1:10302";
    voice = "en_GB-alba-medium"; # see https://rhasspy.github.io/piper-samples/
  };

  # ---------------------------------------------------------------------------
  # Satellite: the PlayStation Eye's microphones, replies on the internal speaker
  # ---------------------------------------------------------------------------
  lanbat.voiceSatellite = {
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

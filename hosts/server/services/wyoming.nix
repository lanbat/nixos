# hosts/server/services/wyoming.nix
#
# Wyoming voice assistant pipeline — server-side services.
#
# Wyoming is Home Assistant's open voice assistant protocol.
# These three services form the processing pipeline that HA uses
# when the Pi satellite captures speech:
#
#   Pi mic → satellite → HA → openwakeword → faster-whisper → intent
#                                                         ↓
#                              Pi speaker ← satellite ← piper (TTS)
#
# All three services listen on 127.0.0.1 only — HA connects to them
# locally.  No server firewall changes are needed.  The only external
# connection is HA (server) → satellite (Pi) on port 10700, which is
# an outbound connection so no server-side rule is required.
#
# Services
# --------
# openwakeword (10300) — detects the wake word ("ok nabu" by default).
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
# HA setup (after deploy)
# -----------------------
# Settings → Devices & Services → Add Integration → Wyoming
#   Add each service above by address.  Then:
# Settings → Voice Assistants → Add Assistant
#   STT: faster-whisper / main
#   TTS: piper / main
#   Wake word: openwakeword (ok_nabu)
# See docs/deployment-checklist.md § Wyoming Voice Assistant.
#
# Always-on: yes — no NFS dependency.
{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Wake word detection
  # ---------------------------------------------------------------------------
  services.wyoming.openwakeword = {
    enable = true;
    uri    = "tcp://127.0.0.1:10300";
    # preloadModels was removed in wyoming-openwakeword 2.0 — models are now
    # loaded on demand when a wake-word detection request arrives.
  };

  # ---------------------------------------------------------------------------
  # Speech-to-text
  # ---------------------------------------------------------------------------
  services.wyoming.faster-whisper.servers."main" = {
    enable   = true;
    uri      = "tcp://127.0.0.1:10301";
    model    = "small-int8";  # ~100 MB; good CPU accuracy/speed balance
    language = "en";
    device   = "cpu";
  };

  # ---------------------------------------------------------------------------
  # Text-to-speech  (British English)
  # ---------------------------------------------------------------------------
  services.wyoming.piper.servers."main" = {
    enable = true;
    uri    = "tcp://127.0.0.1:10302";
    voice  = "en_GB-alba-medium";  # see https://rhasspy.github.io/piper-samples/
  };
}

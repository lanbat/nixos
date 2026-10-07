# services/voice-id.nix
#
# Speaker identification for the voice assistant, in Home Assistant's
# pipeline as its speech-to-text provider: a Wyoming proxy in front of
# faster-whisper (services/wyoming.nix). Every utterance goes through it; it
# streams the audio to faster-whisper as it arrives and returns the transcript
# unchanged, so it works for every satellite and adds nothing to the Pis.
#
# Phase A (this file today): pass-through only. Its log gives, per utterance,
# how long faster-whisper took after the audio ended and how much the proxy
# added, so the cost of sitting in the pipeline is known before speaker
# embeddings are added (phase B). See the spec in docs/pi3-satellite.md.
#
# If it is down, the pipeline has no speech-to-text: it restarts on failure,
# and the faster-whisper entry stays in Home Assistant for a manual switch
# back (docs/failure-modes.md).
#
# Always-on: it is in the speech-to-text path. Listens on the loopback only.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  port = 10303;
  upstream = config.services.wyoming.faster-whisper.servers.main.uri;
  package = pkgs.callPackage ../pkgs/voice-id { };
in
{
  lanbat.services.voice-id.extraPorts = [ port ];

  systemd.services.voice-id = {
    description = "Speaker identification in front of speech-to-text (Wyoming proxy)";
    wantedBy = [ "multi-user.target" ];
    after = [ "wyoming-faster-whisper-main.service" ];
    wants = [ "wyoming-faster-whisper-main.service" ];
    serviceConfig = {
      ExecStart = "${lib.getExe package} --uri tcp://127.0.0.1:${toString port} --upstream ${upstream}";
      DynamicUser = true;
      Restart = "always";
      RestartSec = "2s";
      # Nothing to read or write but the two sockets.
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateDevices = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
    };
  };
}

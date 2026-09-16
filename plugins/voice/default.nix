# plugins/voice/default.nix
#
# Wyoming voice satellite plugin for Pi hosts.
{
  name = "lanbat-voice";
  version = 1;
  roles = [
    "storage-pi"
    "voice-pi"
  ];
  modules = [
    ../../modules/pi/audio.nix
    (
      { config, lib, ... }:
      let
        hostLib = import ../../lib/host.nix { inherit lib; };
        hostKey = config.lanbat.hostKey;
        room = hostLib.voiceRoomForHost config.lanbat.deployment.voiceRooms hostKey;
        domain = config.lanbat.deployment.domain;
      in
      {
        lanbat.voiceSatellite = {
          enable = true;
          name = "Pi Satellite";
          uri = "tcp://0.0.0.0:10700";
          room = room;
          alwaysPlayLocally = true;
          homeAssistant = {
            url = "https://ha.${domain}";
            caFile = ../../secrets/caddy-ca-root.crt;
          };
        };
      }
    )
  ];
}

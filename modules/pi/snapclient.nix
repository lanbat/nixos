# modules/pi/snapclient.nix
#
# Snapcast client — receives and plays the audio stream from the server.
#
# The server-side snapserver is in services/snapcast.nix.
#
# Audio
# -----
# Snapclient plays through the Pi's system-wide PipeWire (modules/pi/audio.nix),
# which mixes it with the TV sessions and the voice satellite's replies. The
# satellite turns it down while the voice assistant listens and answers.
#
# No inbound firewall changes needed — snapclient only makes outbound
# connections to the server on port 1704.
{
  config,
  pkgs,
  lib,
  ...
}:

{
  # nixos-24.11 has no services.snapclient module — run it manually.
  systemd.services.snapclient = {
    description = "Snapcast client";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "sound.target"
      "pipewire.socket"
    ];
    wants = [ "pipewire.socket" ];
    environment.PIPEWIRE_RUNTIME_DIR = "/run/pipewire";
    serviceConfig = {
      ExecStart = "${pkgs.snapcast}/bin/snapclient --host ${config.lanbat.serverIp} --port 1704 --player pipewire";
      Restart = "on-failure";
      RestartSec = "5s";
      User = "snapclient";
      DynamicUser = true;
      SupplementaryGroups = [ "pipewire" ];
    };
  };
}

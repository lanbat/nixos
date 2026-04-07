# hosts/pi/services/snapclient.nix
#
# Snapcast client — receives and plays the audio stream from the server.
#
# The server-side snapserver is in hosts/server/services/snapcast.nix.
#
# Audio
# -----
# PulseAudio is switched to system-wide mode so that both Kodi (media user)
# and Snapclient (snapclient user, a system service) share the same audio
# daemon.  This is appropriate for a fixed-function TV/media appliance;
# it would not be appropriate on a multi-user workstation.
#
# The snapclient user is added to the audio group for PulseAudio access.
#
# Kodi and Snapclient will not fight over the audio device: they both route
# through PulseAudio, which mixes streams and manages the hardware sink.
# If you want Snapcast audio and Kodi audio to never overlap, pause one
# before starting the other — or configure a PulseAudio module-role-cork
# rule to auto-cork Kodi while Snapcast is playing.
#
# No inbound firewall changes needed — snapclient only makes outbound
# connections to the server on port 1704.
{ config, pkgs, lib, ... }:

{
  # Audio is handled by PipeWire (see frontend.nix); snapclient uses PulseAudio
  # compat socket provided by services.pipewire.pulse.enable = true.

  # nixos-24.11 has no services.snapclient module — run it manually.
  systemd.services.snapclient = {
    description = "Snapcast client";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network.target" "sound.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.snapcast}/bin/snapclient --host ${config.lanbat.serverIp} --port 1704";
      Restart      = "on-failure";
      RestartSec   = "5s";
      User         = "snapclient";
      DynamicUser  = true;
      SupplementaryGroups = [ "audio" ];
    };
  };
}

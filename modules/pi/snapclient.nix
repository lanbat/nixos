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
# Snapserver is wherever the profile runs snapcast: snapclient consumes it and
# takes its host from the profile-wide endpoint table rather than assuming the
# server. The port is snapserver's streaming port, which is not the endpoint
# snapcast publishes (that is its web UI), so it stays written out here.
#
# No inbound firewall changes needed — snapclient only makes outbound
# connections to snapserver on port 1704.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  endpointLib = import ../../lib/endpoints.nix { inherit lib; };

  snapserverHost = endpointLib.soleHost {
    endpoints = config.lanbat.endpoints;
    name = "snapcast";
    consumer = "snapclient on ${config.lanbat.hostKey}";
  };
  # The address the server's generated rule admits this host from: the overlay
  # name when the edge runs on the overlay, the LAN address otherwise.
  snapserver = config.lanbat.endpointHost "snapcast" snapserverHost;
in
{
  lanbat.services.snapclient.consumes = [ "snapcast" ];

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
      ExecStart = "${pkgs.snapcast}/bin/snapclient --host ${snapserver} --port 1704 --player pipewire";
      Restart = "on-failure";
      RestartSec = "5s";
      User = "snapclient";
      DynamicUser = true;
      SupplementaryGroups = [ "pipewire" ];
    };
  };
}

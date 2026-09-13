# services/snapcast.nix
#
# Snapcast server — synchronised multi-room audio distribution.
#
# Design
# ------
# - Snapserver broadcasts audio in sync to all connected snapclients (Pi).
# - Music Assistant (services/music-assistant.nix) is the controller/source:
#   it connects to snapserver's control API (port 1705) and registers dynamic
#   TCP input streams per playback via stream_add_stream — it does not write
#   to a named pipe.  See music_assistant/providers/snapcast/player.py in the
#   nixpkgs music-assistant package (_get_or_create_stream).
# - Post-deploy, enable MA's Snapcast provider with "Use existing Snapserver"
#   (127.0.0.1:1705).  Do not let MA launch its built-in snapserver.
# - The web UI / control API (port 1780) is proxied by Caddy at
#   audio.<domain> and protected by Authentik forward auth.
# - Streaming port (1704) and control port (1705) are LAN-open for snapclient.
#
# Stream source
# -------------
# The static "default" stream is an idle TCP listener MA switches away from
# when playing.  MA creates additional streams named "Music Assistant - …"
# on random ports (4953+) via the control API; ffmpeg pipes PCM into them.
#
# Ports
# -----
#   1704 TCP  — streaming   (snapclient connects here)
#   1705 TCP  — control API (snapclient, MA, web UI)
#   1780 TCP  — HTTP API + web UI (proxied by Caddy, localhost-only)
#
# Always-on: yes.  No NFS dependency.
{ config, ... }:

{
  lanbat.services.snapcast = {
    subdomain = "audio";
    port = 1780;
    extraPorts = [
      1704 # streaming
      1705 # control
    ];
    auth = "forward-auth";
    dashboard = {
      group = "Utilities";
      name = "Snapcast";
      description = "Multi-room audio";
    };
  };

  services.snapserver = {
    enable = true;

    settings = {
      tcp-streaming = {
        enabled = true;
        port = 1704;
        bind_to_address = "0.0.0.0";
      };

      tcp-control = {
        enabled = true;
        port = 1705;
        bind_to_address = "0.0.0.0";
      };

      http = {
        enabled = true;
        port = 1780;
        bind_to_address = "127.0.0.1";
      };

      # Idle "default" stream — MA sets groups back here when playback stops.
      # Port 4952 is below MA's dynamic range (4953–5153).
      stream.source = "tcp://127.0.0.1:4952?name=default&mode=server&sampleformat=48000:16:2&codec=flac&idle_threshold=60000";
    };
  };

  networking.firewall.allowedTCPPorts = [
    1704
    1705
  ];
}

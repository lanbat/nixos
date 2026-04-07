# hosts/server/services/snapcast.nix
#
# Snapcast server — synchronised multi-room audio.
#
# Design
# ------
# - Snapserver receives audio from a named pipe and broadcasts it in sync
#   to all connected snapclients (Pi, and any future clients).
# - The web UI / control API (port 1780) is proxied by Caddy at
#   audio.<domain> and protected by Authentik forward auth (Snapcast has
#   no native auth).
# - The streaming port (1704) and control port (1705) must be open to the
#   LAN without auth so snapclient can connect.
#
# Audio source
# ------------
# Snapcast does not generate audio — it rebroadcasts whatever is written
# to its input pipe.  Wire a player to /run/snapserver/main.fifo, e.g.:
#
#   MPD (add to mpd.conf or services.mpd.extraConfig):
#     audio_output {
#       type    "fifo"
#       name    "Snapcast"
#       path    "/run/snapserver/main.fifo"
#       format  "48000:16:2"
#       mixer_type "software"
#     }
#
#   librespot (Spotify Connect):
#     --backend pipe --device /run/snapserver/main.fifo
#
#   shairport-sync (AirPlay):
#     set backend to "pipe" with output path /run/snapserver/main.fifo
#
# The sampleformat (48000:16:2 = 48 kHz, 16-bit, stereo) must match what
# your source produces.  Adjust if your player uses a different format.
#
# Ports
# -----
#   1704 TCP  — streaming   (snapclient connects here)
#   1705 TCP  — control API (snapclient + web UI use this)
#   1780 TCP  — HTTP API + web UI (proxied by Caddy, LAN-only)
#
# Always-on: yes. No NFS dependency.
{ config, ... }:

{
  services.snapserver = {
    enable = true;

    settings = {
      # Streaming port — snapclient connects here from the LAN.
      tcp-streaming = {
        enabled         = true;
        port            = 1704;
        bind_to_address = "0.0.0.0";
      };

      # Control/JSON-RPC port — snapclient + web UI use this.
      tcp-control = {
        enabled         = true;
        port            = 1705;
        bind_to_address = "0.0.0.0"; # snapclient needs to reach this from the LAN
      };

      # HTTP JSON-RPC + web UI — Caddy proxies this; localhost-only.
      http = {
        enabled         = true;
        port            = 1780;
        bind_to_address = "127.0.0.1";
      };

      # Audio source: named pipe written by MPD/librespot/shairport-sync.
      # URI format: pipe://<path>?name=<stream-name>&<key>=<val>&...
      stream.source = "pipe:///run/snapserver/main.fifo?name=main&sampleformat=48000:16:2&codec=flac&mode=read";
    };
  };

  # Create the FIFO and its parent dir before snapserver starts.
  # /run is tmpfs — these are re-created on each boot.
  systemd.tmpfiles.rules = [
    "d /run/snapserver                0755 snapserver snapserver -"
    "p /run/snapserver/main.fifo      0660 snapserver snapserver -"
  ];

  # Open streaming and control ports to the LAN.
  networking.firewall.allowedTCPPorts = [ 1704 1705 ];
}

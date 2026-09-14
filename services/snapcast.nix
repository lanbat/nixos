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
# Discovery
# ---------
# Snapclients (Snapdroid on Android TV, snapclient on the Pi) find the server
# via mDNS (_snapcast._tcp / _snapcast-ctrl._tcp).  That requires mdns_enabled
# and publish in snapserver.conf, plus Avahi D-Bus access (DynamicUser blocks
# it by default — see the avahi-snapserver group below).
#
# Snapserver must listen on IPv6 (::) as well as IPv4.  Avahi publishes the
# host's IPv6 addresses in mDNS and Android clients prefer them; with a v4-only
# bind they get "connection refused".  Binding :: accepts both (Linux dual-stack).
# Avahi IPv6 is also disabled so mDNS prefers the LAN IPv4.
# http.host is the LAN IP (cover-art URLs) — same address snapclient uses on the Pi.
#
# Always-on: yes.  No NFS dependency.
{ config, pkgs, ... }:

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
      server = {
        mdns_enabled = true;
      };

      tcp-streaming = {
        enabled = true;
        port = 1704;
        bind_to_address = "::";
        publish = true;
      };

      tcp-control = {
        enabled = true;
        port = 1705;
        bind_to_address = "::";
        publish = true;
      };

      http = {
        enabled = true;
        port = 1780;
        bind_to_address = "127.0.0.1";
        host = config.lanbat.serverIp;
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

  # IPv4-only mDNS — see Discovery above.  Merged into avahi-daemon.conf from
  # services/samba.nix.
  services.avahi.ipv6 = false;

  # Let snapserver register _snapcast._tcp with avahi-daemon (already enabled
  # for Samba in services/samba.nix).  Upstream fix: nixpkgs#548066.
  users.groups.avahi-snapserver = { };

  systemd.services.snapserver = {
    after = [ "avahi-daemon.service" ];
    serviceConfig.SupplementaryGroups = [ "avahi-snapserver" ];
  };

  services.dbus.packages = [
    (pkgs.writeTextDir "share/dbus-1/system.d/snapserver-avahi.conf" ''
      <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
      <busconfig>
        <policy group="avahi-snapserver">
          <allow send_destination="org.freedesktop.Avahi"/>
          <allow receive_sender="org.freedesktop.Avahi"/>
        </policy>
      </busconfig>
    '')
  ];
}

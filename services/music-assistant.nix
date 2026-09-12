# services/music-assistant.nix
#
# Music Assistant — music library controller and multi-room orchestrator.
#
# Why the NixOS module and not a container?
#   `services.music-assistant` exists in pinned nixpkgs (2.7.x) and runs as a
#   native systemd service on the host network stack — no rootless Podman
#   multicast caveats.  CONTRIBUTING.md prefers native modules when available.
#
# Snapcast integration (distribution layer)
# -----------------------------------------
# Snapcast stays declarative in services/snapcast.nix (snapserver on 1704/1705).
# Music Assistant does NOT write to the old FIFO.  When the Snapcast player
# provider is enabled in the MA UI with "Use existing Snapserver", MA connects
# to snapserver's control API (port 1705) and creates per-playback TCP streams
# dynamically via stream_add_stream — see music_assistant/providers/snapcast/
# player.py::_get_or_create_stream in the nixpkgs package source.
#
# Post-deploy: Settings → Player Providers → Snapcast → enable "Use existing
# Snapserver", host 127.0.0.1, control port 1705.  Do NOT use MA's built-in
# snapserver (it would bind the same ports).
#
# Local music library
# -------------------
# The filesystem_local provider reads /srv/storage/a/media/music over NFS.
# That path is Pi-backed (automount, not workload-gated).  MA is always-on:
# we deliberately avoid lanbat.services.*.nfs.drives (which would stop MA when
# the Pi disappears).  The service starts without the mount; library scans fail
# gracefully until NFS is available.
#
# Always-on: yes.  State in /var/lib/music-assistant (provider config, playlists).
{
  config,
  lib,
  ...
}:

let
  musicLibrary = "/srv/storage/a/media/music";
in
{
  lanbat.services.music-assistant = {
    subdomain = "music";
    port = 8095;
    extraPorts = [
      8097 # MA stream server (players / imageproxy)
    ];
    auth = "forward-auth";
    account = {
      uid = 964;
      extraGroups = [ "media" ];
    };
    dashboard = {
      group = "Media";
      name = "Music Assistant";
      description = "Multi-room music controller";
    };
  };

  services.music-assistant = {
    enable = true;
    openFirewall = false; # Caddy handles the web UI; 8095 stays closed on the firewall.
    providers = [
      "snapcast"
      "filesystem_local"
    ];
  };

  # Upstream uses DynamicUser; override to a pinned account in the media group
  # so filesystem_local can read NFS-mounted tracks (0750, group media).
  systemd.services.music-assistant = {
    after = [
      "network-online.target"
      "snapserver.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "music-assistant";
      Group = "music-assistant";
      SupplementaryGroups = [ "media" ];
      ReadOnlyPaths = [ musicLibrary ];
    };
  };
}

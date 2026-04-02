# modules/common/users.nix
#
# Shared user/group definitions that must be consistent across both machines
# so that NFS uid/gid mapping works without idmapd tricks.
#
# Rules:
#  - UIDs/GIDs below 1000 are system accounts.
#  - Service accounts (jellyfin, nextcloud, etc.) live in 900-999.
#  - Human users start at 1000.
#  - The "media" group (GID 988) owns all bulk media paths.
#  - The Pi "nfs-access" restriction is handled via exports, not separate UIDs.
#
# Add human users in hosts/<machine>/default.nix with
#   users.users.alice = { ... isNormalUser = true; uid = 1001; ... };
{ lib, ... }:

{
  # Declare groups so GIDs are stable across both machines.
  users.groups = {
    media    = { gid = 988; };   # bulk media read/write
    svc      = { gid = 989; };   # generic service group
    private  = { gid = 987; };   # restricted private shares — add users explicitly
    nextcloud = { gid = 990; };
    immich    = { gid = 991; };
    jellyfin  = { gid = 992; };  # NixOS jellyfin module creates this too; keep in sync
    ha        = { gid = 993; };
    qbt       = { gid = 994; };
    frigate   = { gid = 995; };
  };

  # Service accounts.
  # Many of these are also created by the relevant NixOS service modules;
  # declaring them here makes UIDs deterministic.
  users.users = {
    nextcloud = { uid = 990; group = "nextcloud"; isSystemUser = true; };
    immich    = { uid = 991; group = "immich";    isSystemUser = true; };
    jellyfin  = { uid = 992; group = "jellyfin";  isSystemUser = true; extraGroups = [ "media" ]; };
    ha        = { uid = 993; group = "ha";        isSystemUser = true; };
    qbt       = { uid = 994; group = "qbt";       isSystemUser = true; extraGroups = [ "media" ]; };
    frigate   = { uid = 995; group = "frigate";   isSystemUser = true; extraGroups = [ "media" ]; };

    # Pi "media" user — runs the TV launcher / Kodi / RetroArch.
    # Only present on the Pi but declared here so UID is consistent if needed.
    media = {
      uid  = 1000;
      group = "media";
      isNormalUser = true;
      extraGroups  = [ "audio" "video" "input" ];
      # Password set via initial hash or agenix secret; no sudo.
    };
  };
}

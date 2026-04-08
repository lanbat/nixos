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
# Container service accounts (immich, qbt, frigate, searxng, homepage,
# authentik, bitmagnet) have linger=true, a home dir, and subUid/subGid
# ranges so they can run rootless Podman containers under systemd.
# Their sub-UID ranges are non-overlapping, starting at 200000.
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
    # UIDs/GIDs 996-999 are all taken by NixOS dynamic services on unstable
    # (redis-authentik=996, nscd=997, influxdb2=998, avahi=999).
    # Use 960-963 which are below the NixOS dynamic allocation zone.
    searxng   = { gid = 960; };
    homepage  = { gid = 961; };
    authentik = { gid = 962; };
    bitmagnet = { gid = 963; };
  };

  # Service accounts.
  # Many of these are also created by the relevant NixOS service modules;
  # declaring them here makes UIDs deterministic.
  users.users = {
    # NixOS-native service accounts (no OCI container, no rootless Podman needed).
    nextcloud = { uid = 990; group = "nextcloud"; isSystemUser = true; };
    jellyfin  = { uid = 992; group = "jellyfin";  isSystemUser = true; extraGroups = [ "media" ]; };
    ha        = { uid = 993; group = "ha";        isSystemUser = true; };

    # OCI container service accounts — need rootless Podman support:
    #   linger=true      → systemd-logind creates /run/user/<uid> at boot (XDG_RUNTIME_DIR)
    #   home + createHome → Podman stores container state under $HOME/.local/share/containers
    #   subUidRanges/subGidRanges → Linux user namespace UID/GID mapping for rootless mode

    immich = {
      uid = 991; group = "immich"; isSystemUser = true;
      linger = true;
      home = "/var/lib/containers/immich"; createHome = true;
      subUidRanges = [{ startUid = 200000; count = 65536; }];
      subGidRanges = [{ startGid = 200000; count = 65536; }];
    };

    qbt = {
      uid = 994; group = "qbt"; isSystemUser = true; extraGroups = [ "media" ];
      linger = true;
      home = "/var/lib/containers/qbt"; createHome = true;
      subUidRanges = [{ startUid = 265536; count = 65536; }];
      subGidRanges = [{ startGid = 265536; count = 65536; }];
    };

    frigate = {
      uid = 995; group = "frigate"; isSystemUser = true;
      # media — writes recordings/clips to NFS
      # render + video — /dev/dri access for OpenVINO GPU inference
      extraGroups = [ "media" "render" "video" ];
      linger = true;
      home = "/var/lib/containers/frigate"; createHome = true;
      subUidRanges = [{ startUid = 331072; count = 65536; }];
      subGidRanges = [
        { startGid = 331072; count = 65536; }
        { startGid = 26;  count = 1; }   # video — /dev/dri access
        { startGid = 303; count = 1; }   # render — /dev/dri access
      ];
    };

    searxng = {
      uid = 960; group = "searxng"; isSystemUser = true;
      linger = true;
      home = "/var/lib/containers/searxng"; createHome = true;
      subUidRanges = [{ startUid = 396608; count = 65536; }];
      subGidRanges = [{ startGid = 396608; count = 65536; }];
    };

    homepage = {
      uid = 961; group = "homepage"; isSystemUser = true;
      linger = true;
      home = "/var/lib/containers/homepage"; createHome = true;
      subUidRanges = [{ startUid = 462144; count = 65536; }];
      subGidRanges = [{ startGid = 462144; count = 65536; }];
    };

    # Authentik image runs as internal UID 1000 ("authentik" inside the container).
    # We remap container UID 1000 → host authentik (UID 962) via --uidmap in the
    # container extraOptions.  Directories owned by authentik on the host appear
    # as UID 1000 inside the container.
    authentik = {
      uid = 962; group = "authentik"; isSystemUser = true;
      linger = true;
      home = "/var/lib/containers/authentik"; createHome = true;
      # subUid start 527680: container UID 0-999 → 527680-528679,
      # container UID 1000 remapped to this user (see authentik.nix --uidmap).
      subUidRanges = [{ startUid = 527680; count = 65536; }];
      subGidRanges = [{ startGid = 527680; count = 65536; }];
    };

    bitmagnet = {
      uid = 963; group = "bitmagnet"; isSystemUser = true;
      linger = true;
      home = "/var/lib/containers/bitmagnet"; createHome = true;
      subUidRanges = [{ startUid = 593216; count = 65536; }];
      subGidRanges = [{ startGid = 593216; count = 65536; }];
    };

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

# hosts/server/services/frigate.nix
#
# Frigate NVR — camera recording and detection.
#
# Storage
# -------
# All state is local (always-on tier):
#   /var/lib/frigate/db/      — SQLite event metadata
#   /var/lib/frigate/recordings/ — 24h rolling recordings
#   /var/cache/frigate/       — clip buffer (safe to lose)
#
# rclone cloud sync will be added later.
#
# Detector
# --------
# Intel OpenVINO via /dev/dri (iGPU).
#
# Credentials
# -----------
# Camera RTSP credentials: secrets/frigate-rtsp-env.age
#   FRIGATE_RTSP_USER=<camera user>
#   FRIGATE_RTSP_PASSWORD=<camera password>
# MQTT password: secrets/mosquitto-frigate-pass.age (plaintext)
#
# Both are combined into /run/frigate-env by ExecStartPre and injected
# into the container via environmentFiles.
#
# Home Assistant integration
# --------------------------
# Frigate publishes events via MQTT → Home Assistant listens.
{ config, pkgs, lib, ... }:

let
  frigateConfig = pkgs.writeText "frigate.yml" ''
    mqtt:
      enabled: true
      host: 127.0.0.1
      port: 1883
      user: frigate
      password: "{FRIGATE_MQTT_PASSWORD}"

    database:
      path: /media/frigate/db/frigate.db

    record:
      enabled: true
      detections:
        retain:
          days: 30
      alerts:
        retain:
          days: 30

    snapshots:
      enabled: true
      retain:
        default: 30

    detectors:
      cpu1:
        type: cpu
        num_threads: 3
        # OpenVINO detector broken in Frigate 0.17.1 — model.path key ignored;
        # new model management API returns None. Revisit when Frigate documents it.

    ffmpeg:
      # Use TCP transport to avoid RTP packet reordering from cameras over WiFi/UDP.
      input_args: preset-rtsp-generic
      # Disable auto-detected vaapi hwaccel — fails in rootless Podman without DRM access.
      hwaccel_args: []

    cameras:
      c1:
        ffmpeg:
          inputs:
            - path: rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@c1.10ctr.vg.cd/h264Preview_01_sub
              roles: [ detect ]
            - path: rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@c1.10ctr.vg.cd/h264Preview_01_main
              roles: [ record ]
        detect:
          width:  640
          height: 480
          fps:    5
        motion:
          mask: []
  '';
in
{
  # ---------------------------------------------------------------------------
  # Frigate container
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers.containers."frigate" = {
    image = "ghcr.io/blakeblackshear/frigate:stable";

    # environmentFiles would become systemd EnvironmentFile= (read before
    # ExecStartPre runs, so the file doesn't exist yet).  Use --env-file in
    # extraOptions instead — podman reads it during ExecStart, after ExecStartPre
    # has already created /run/frigate-env.

    volumes = [
      "${frigateConfig}:/config/config.yml:ro"
      "/var/lib/frigate/db:/media/frigate/db"
      "/var/lib/frigate/recordings:/media/frigate/recordings"
      "/var/cache/frigate:/tmp/cache"
      "/etc/localtime:/etc/localtime:ro"
    ];

    ports = [ "127.0.0.1:5000:5000" "127.0.0.1:8554:8554" ];

    extraOptions = [
      "--shm-size=256m"
      "--device=/dev/dri"
      # Pass the host frigate user's supplemental groups (render, video) into the
      # container by GID.  --group-add=keep-groups is the rootless Podman way —
      # using group names would look them up in the container's /etc/group, which
      # doesn't have render/video.
      "--group-add=keep-groups"
      # Env file created by ExecStartPre — pass directly to the container.
      "--env-file=/run/frigate-env"
    ];

    podman.user = "frigate";
    user = "0";
    autoStart = true;
  };

  # ---------------------------------------------------------------------------
  # Write combined env file before container starts
  # ---------------------------------------------------------------------------
  systemd.services."podman-frigate" = {
    serviceConfig = {
      Restart    = lib.mkForce "on-failure";
      RestartSec = "15s";
      ExecStartPre = [
        # Runs as root (+ prefix) even though the service User=frigate.
        # Combines both secrets into /run/frigate-env and hands ownership
        # to the frigate user so Podman (running rootless as frigate) can
        # read the env file.
        "+${pkgs.writeShellScript "frigate-write-env" ''
          set -euo pipefail
          {
            # awk 1 ensures a trailing newline even if the secret file lacks one,
            # preventing the next printf from being appended to the last line.
            ${pkgs.gawk}/bin/awk 1 ${config.age.secrets.frigate-rtsp-env.path}
            printf 'FRIGATE_MQTT_PASSWORD=%s\n' \
              "$(${pkgs.coreutils}/bin/tr -d '\n' < ${config.age.secrets.mosquitto-frigate-pass.path})"
          } > /run/frigate-env
          chown frigate:frigate /run/frigate-env
          chmod 600 /run/frigate-env
        ''}"
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # Secrets
  # ---------------------------------------------------------------------------
  age.secrets.frigate-rtsp-env = {
    file  = ../../../secrets/frigate-rtsp-env.age;
    owner = "root";
  };

  # ---------------------------------------------------------------------------
  # State directories
  # ---------------------------------------------------------------------------
  systemd.tmpfiles.rules = [
    "d /var/lib/frigate/db          0750 frigate frigate -"
    "d /var/lib/frigate/recordings  0750 frigate frigate -"
  ];
}

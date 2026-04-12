# hosts/server/services/frigate.nix
#
# Frigate NVR — camera recording and detection.
#
# Temporary UI tuning
# -------------------
# The config is mounted read-only so Frigate's web UI can't save changes.
# To temporarily enable UI editing (zones, masks, filters), run on the server:
#
#   src=$(sudo -u frigate podman inspect frigate \
#     --format '{{range .Mounts}}{{if eq .Destination "/config/config.yml"}}{{.Source}}{{end}}{{end}}')
#   cp "$src" /var/lib/frigate/config.yml
#   chown frigate:frigate /var/lib/frigate/config.yml
#   systemctl stop podman-frigate
#   mount --bind /var/lib/frigate/config.yml "$src"
#   systemctl start podman-frigate
#
# The UI can now save changes. When done, retrieve the tuned config:
#   cat /var/lib/frigate/config.yml
# Then port the values back into this file and rebuild. A nixos-rebuild or
# reboot undoes the bind mount automatically.
#
# Storage
# -------
# All state is local (always-on tier):
#   /var/lib/frigate/db/         — SQLite event metadata
#   /var/lib/frigate/clips/      — review thumbnails + preview videos
#   /var/lib/frigate/recordings/ — 24h rolling recordings
#   /var/cache/frigate/          — clip buffer (safe to lose)
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

    # Global model config — read by all detectors via detector_config.model
    # (OvDetectorConfig inherits model from BaseDetectorConfig, not its own field)
    model:
      path: /openvino-model/ssdlite_mobilenet_v2.xml
      model_type: ssd
      width: 300
      height: 300

    detectors:
      ov:
        type: openvino
        device: AUTO

    lpr:
      enabled: true

    # go2rtc ingests camera feeds and re-serves them as local RTSP.
    # http-flv is the recommended transport for Reolink ≤5 MP cameras.
    go2rtc:
      streams:
        c1:
          - "ffmpeg:http://c1.10ctr.vg.cd/flv?port=1935&app=bcs&stream=channel0_main.bcs&user={FRIGATE_RTSP_USER}&password={FRIGATE_RTSP_PASSWORD}#video=copy#audio=copy#audio=opus"
        c1_sub:
          - "ffmpeg:http://c1.10ctr.vg.cd/flv?port=1935&app=bcs&stream=channel0_ext.bcs&user={FRIGATE_RTSP_USER}&password={FRIGATE_RTSP_PASSWORD}"

    ffmpeg:
      # Disable auto-detected vaapi hwaccel — fails in rootless Podman without DRM access.
      hwaccel_args: []

    cameras:
      c1:
        ffmpeg:
          inputs:
            - path: rtsp://127.0.0.1:8554/c1_sub
              input_args: preset-rtsp-restream
              roles: [ detect ]
            - path: rtsp://127.0.0.1:8554/c1
              input_args: preset-rtsp-restream
              roles: [ record ]
        detect:
          enabled: true
          width:  640
          height: 480
          fps:    5
        lpr:
          enabled: true
        zones:
          driveway:
            coordinates: 0,0.928,0,0.298,0.328,0.124,0.586,0.044,0.712,0.014,0.793,0,1,0,1,1,0.435,1,0.438,0.922,0.012,0.92,0.012,0.978,0.441,0.978,0.433,1,0,1
            inertia: 3
            loitering_time: 0
          pavement:
            coordinates: 0.003,0.212,0.183,0.092,0.315,0.024,0.37,0,0,0
            inertia: 3
            loitering_time: 0
            friendly_name: Pavement
        objects:
          track:
            - person
            - bicycle
            - car
            - motorcycle
            - bus
            - truck
            - dog
            - cat
            - bird
          filters:
            person:
              min_score: 0.6
              threshold: 0.7
            car:
              min_score: 0.6
              threshold: 0.7
            truck:
              min_score: 0.6
              threshold: 0.7
            motorcycle:
              min_score: 0.85
              threshold: 0.9
              max_area: 40000
            bus:
              min_score: 0.85
              threshold: 0.9
            bicycle:
              min_score: 0.85
              threshold: 0.9
            dog:
              min_score: 0.6
              threshold: 0.7
            cat:
              min_score: 0.6
              threshold: 0.7
            bird:
              min_score: 0.7
              threshold: 0.8
        review:
          alerts:
            labels:
              - person
              - car
              - motorcycle
              - bus
              - truck
              - bicycle
            required_zones:
              - driveway
              - pavement
          detections:
            labels:
              - person
              - car
              - motorcycle
              - bus
              - truck
              - bicycle
              - dog
              - cat
              - bird
            required_zones:
              - driveway
              - pavement
        motion:
          mask:
            - 0,0.218,0.385,0,0.599,0,0.755,0,0.604,0.036,0.496,0.065,0.33,0.116,0.185,0.189,0,0.291
        notifications:
          enabled: true

    notifications:
      enabled: true

    semantic_search:
      enabled: true
      model_size: small

    face_recognition:
      enabled: false
      model_size: small

    classification:
      bird:
        enabled: false

    version: 0.17-0
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
      "/var/lib/frigate/clips:/media/frigate/clips"
      "/var/lib/frigate/recordings:/media/frigate/recordings"
      "/var/cache/frigate:/tmp/cache"
      "/etc/localtime:/etc/localtime:ro"
    ];

    extraOptions = [
      "--network=host"
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
    "d /var/lib/frigate/clips       0750 frigate frigate -"
    "d /var/lib/frigate/recordings  0750 frigate frigate -"
  ];
}

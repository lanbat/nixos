# services/frigate.nix
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
 #   /var/lib/frigate/clips/      — review snapshots/clips (14-day rolling)
 #   /var/lib/frigate/recordings/ — 7-day motion-only recordings (sub stream)
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
{
  config,
  pkgs,
  lib,
  ...
}:

let
  yolov8nOpenVinoModel = pkgs.callPackage ../pkgs/frigate-yolov8n-openvino-model { };

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
      # Motion-only recording on the sub stream, 7-day rolling window. Time with
      # no motion produces no recording, so the retained volume stays bounded
      # (was: 5MP 24/7 with no real retain = ~27G/day).
      motion:
        days: 7
      # Retain detection/alert event clips + snapshots (the review "pictures")
      # for 14 days — the 2nd data sink (~3.7G/day on the busy Tennison Road).
      detections:
        retain:
          days: 14
      alerts:
        retain:
          days: 14

    snapshots:
      enabled: true
      retain:
        default: 30

    # Global model config — read by all detectors via detector_config.model
    # (OvDetectorConfig inherits model from BaseDetectorConfig, not its own field)
    model:
      path: /models/yolov8n_openvino_model/yolov8n.xml
      labelmap_path: /labelmap/coco-80.txt
      model_type: yolo-generic
      width: 640
      height: 640
      input_tensor: nchw
      input_dtype: float
      input_pixel_format: rgb

    detectors:
      ov:
        type: openvino
        device: AUTO

    # LPR uses YOLOv9 plate detection + PaddleOCR on detected cars/motorcycles.
    # Requires car/motorcycle in objects.track — do not add license_plate (Frigate+ only).
    lpr:
      enabled: true
      detection_threshold: 0.55
      min_area: 800
      recognition_threshold: 0.85
      min_plate_length: 7
      match_distance: 1
      format: "^[A-Z]{2}[0-9]{2} ?[A-Z]{3}$"
      debug_save_plates: true
      replace_rules:
        - pattern: "O"
          replacement: "0"
        - pattern: "I"
          replacement: "1"

    # go2rtc ingests camera feeds and re-serves them as local RTSP.
    # http-flv is the recommended transport for Reolink ≤5 MP cameras.
    go2rtc:
      streams:
        c1:
          - "ffmpeg:http://c1.${config.lanbat.deployment.rootDomain}/flv?port=1935&app=bcs&stream=channel0_main.bcs&user={FRIGATE_RTSP_USER}&password={FRIGATE_RTSP_PASSWORD}#video=copy#audio=copy#audio=opus"
        c1_sub:
          - "ffmpeg:http://c1.${config.lanbat.deployment.rootDomain}/flv?port=1935&app=bcs&stream=channel0_ext.bcs&user={FRIGATE_RTSP_USER}&password={FRIGATE_RTSP_PASSWORD}"

    ffmpeg:
      # Disable auto-detected vaapi hwaccel — fails in rootless Podman without DRM access.
      hwaccel_args: []

    cameras:
      c1:
        ffmpeg:
          inputs:
            # Main stream (2560x1920) for detection — sub stream is too soft for
            # overhead/distant objects on Tennison Road.
            - path: rtsp://127.0.0.1:8554/c1
              input_args: preset-rtsp-restream
              roles: [ detect ]
            # Sub stream for recording — far smaller than the 5MP main, so the
            # 7-day motion-only rolling window stays bounded. Detection (and all
            # AI: LPR, zones, semantic search) still runs on the main stream.
            - path: rtsp://127.0.0.1:8554/c1_sub
              input_args: preset-rtsp-restream
              roles: [ record ]
        detect:
          enabled: true
          width:  1280
          height: 960
          fps:    7
          min_initialized: 2
        lpr:
          enabled: true
          # Overhead first-storey view — mild enhancement helps OCR without blurring.
          enhancement: 3
          # Lower than global default; plates are smaller at driveway distance.
          min_area: 600
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
          road:
            coordinates: 0,0,1,0,1,0.22,0,0.22
            inertia: 3
            loitering_time: 0
            friendly_name: Tennison Road
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
              min_score: 0.35
              threshold: 0.45
            car:
              min_score: 0.35
              threshold: 0.45
            truck:
              min_score: 0.35
              threshold: 0.45
            motorcycle:
              min_score: 0.5
              threshold: 0.6
            bus:
              min_score: 0.5
              threshold: 0.65
            bicycle:
              min_score: 0.5
              threshold: 0.65
            dog:
              min_score: 0.45
              threshold: 0.55
            cat:
              min_score: 0.45
              threshold: 0.55
            bird:
              min_score: 0.55
              threshold: 0.65
        review:
          alerts:
            labels:
              - person
              - car
              - motorcycle
              - bus
              - truck
              - bicycle
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
        motion:
          # Overhead driveway + distant road traffic need sensitive motion to
          # trigger object detection. Do not mask the road area.
          threshold: 10
          contour_area: 5
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
  lanbat.services.frigate = {
    subdomain = "nvr";
    port = 5000;
    extraPorts = [ 8554 ]; # RTSP restream
    auth = "forward-auth";
    # Homepage's Frigate widget calls /api/* without an Authentik session.
    caddy.authBypassPaths = [ "/api/*" ];
    account = {
      uid = 995;
      container = true;
      # media: writes recordings to NFS. render + video: /dev/dri for OpenVINO.
      extraGroups = [
        "media"
        "render"
        "video"
      ];
      # Map the host video (26) and render (303) groups into the container.
      extraSubGidRanges = [
        {
          startGid = 26;
          count = 1;
        }
        {
          startGid = 303;
          count = 1;
        }
      ];
    };
    secrets = {
      frigate-rtsp-env.owner = "root"; # read by ExecStartPre
      rclone-frigate-config = { };
    };
    dashboard = {
      group = "Surveillance";
      name = "Frigate";
      description = "NVR & object detection";
      widget = {
        type = "frigate";
        enableRecentEvents = true;
      };
    };
  };

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
      "${yolov8nOpenVinoModel}:/models/yolov8n_openvino_model:ro"
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
    # Order after the frigate user's systemd session (linger bus at
    # /run/user/995) — crun's systemd cgroup manager needs that bus to place
    # the pause process in its sandbox cgroup.
    after = [ "user@995.service" ];
    wants = [ "user@995.service" ];
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
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
  # State directories
  # ---------------------------------------------------------------------------
  systemd.tmpfiles.rules = [
    "d /var/cache/frigate           0750 frigate frigate -"
    "d /var/lib/frigate/db          0750 frigate frigate -"
    "d /var/lib/frigate/clips       0750 frigate frigate -"
    "d /var/lib/frigate/recordings  0750 frigate frigate -"
  ];
}

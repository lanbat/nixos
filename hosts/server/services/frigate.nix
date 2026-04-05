# hosts/server/services/frigate.nix
#
# Frigate NVR — camera recording and detection.
#
# Storage split
# -------------
# Server-local:
#   /var/lib/frigate/config/   — frigate.yml
#   /var/lib/frigate/db/       — frigate.db (SQLite event metadata)
#   /var/cache/frigate/        — clips buffer / tmpfs safe to lose
#
# Pi-backed via NFS (/srv/storage/a):
#   /srv/storage/a/surveillance/         — recordings (24h-rolling)
#   /srv/storage/a/surveillance/clips/   — event clips
#   /srv/storage/a/surveillance/exports/ — manually exported clips
#
# NFS dependency:
#   Frigate's recording engine depends on the surveillance path.
#   If NFS disappears, Frigate should stop recording rather than write to
#   wrong paths.  We declare the dependency.
#   Frigate itself can still be running for live view if desired — but
#   the cleanest model is to stop it entirely and restart when NFS returns.
#
# Hardware acceleration
# ---------------------
# Frigate supports several detectors:
#   - CPU (works everywhere, slow)
#   - Google Coral USB/PCIe (fast, low power — recommended for house cameras)
#   - OpenVINO (Intel iGPU — good if server has Intel graphics)
#   - NVIDIA CUDA (if server has NVIDIA GPU)
# Set FRIGATE_DETECTOR below.  Default is CPU so it works out of the box.
#
# Cloud sync (rclone)
# -------------------
# A systemd service runs rclone sync after each new recording file closes.
# Uses inotifywait to detect file-close events in the recordings dir.
# Uploads clips (event-driven) and optionally full recordings.
# See rclone config template in pkgs/scripts/rclone-sync-frigate.sh.
#
# Home Assistant integration
# --------------------------
# Frigate publishes events via MQTT → Home Assistant listens.
# HA sends push notifications via the mobile app.
# Set the MQTT broker to localhost (Mosquitto — see services/mosquitto.nix).
{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Frigate container
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers.containers."frigate" = {
    image = "ghcr.io/blakeblackshear/frigate:stable";

    environment = {
      FRIGATE_RTSP_PASSWORD = "CHANGE_ME"; # not used if cameras are RTSP URL only
    };

    volumes = [
      "/var/lib/frigate/config/frigate.yml:/config/config.yml:ro"
      "/var/lib/frigate/db:/media/frigate/db"
      "/srv/storage/a/surveillance:/media/frigate/recordings"
      "/var/cache/frigate:/tmp/cache"
      "/etc/localtime:/etc/localtime:ro"
      # Coral USB: uncomment below and add the device option
      # "/dev/bus/usb:/dev/bus/usb"
    ];

    ports = [ "127.0.0.1:5000:5000" "127.0.0.1:8554:8554" ];

    extraOptions = [
      # Memory-mapped shm for Frigate's frame buffer.
      "--shm-size=256m"
      # For Intel OpenVINO: "--device=/dev/dri"
      # For Coral USB:      "--device=/dev/bus/usb"
    ];

    autoStart = false; # managed via NFS dependency
  };

  # ---------------------------------------------------------------------------
  # Frigate config file — edit cameras here.
  # ---------------------------------------------------------------------------
  environment.etc."frigate/frigate.yml".text = ''
    mqtt:
      enabled: true
      host: 127.0.0.1
      port: 1883
      # user / password if Mosquitto requires auth — set via MQTT_USER/MQTT_PASSWORD

    database:
      path: /media/frigate/db/frigate.db

    record:
      enabled: true
      retain:
        days: 7          # keep 7 days of 24h recordings on Pi storage
        mode: all        # record all motion + events
      events:
        retain:
          default: 30    # keep event clips for 30 days
          mode: active_objects

    snapshots:
      enabled: true
      retain:
        default: 30

    detectors:
      cpu1:
        type: cpu       # CHANGE_ME: set to "coral", "openvino", or "tensorrt"
        num_threads: 3

    # Define cameras here.  One example:
    cameras:
      EXAMPLE_CAMERA_NAME:
        ffmpeg:
          inputs:
            - path: rtsp://CAMERA_USER:CAMERA_PASS@EXAMPLE_CAMERA_IP/stream1
              roles: [ detect, record ]
        detect:
          width:  1920
          height: 1080
          fps:    5
        motion:
          mask: []
  '';

  systemd.services."frigate-config-link" = {
    description = "Link Frigate config";
    wantedBy    = [ "podman-frigate.service" ];
    before      = [ "podman-frigate.service" ];
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c 'cp /etc/frigate/frigate.yml /var/lib/frigate/config/frigate.yml'";
      RemainAfterExit = true;
    };
  };

  # ---------------------------------------------------------------------------
  # NFS dependency
  # ---------------------------------------------------------------------------
  lanbat.nfsDependentServices."podman-frigate" = [ "a" ];

  systemd.services."podman-frigate" = {
    wantedBy   = [ "multi-user.target" ];
    serviceConfig = {
      Restart    = lib.mkForce "on-failure";
      RestartSec = "15s";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/frigate/config             0750 frigate frigate -"
    "d /srv/storage/a/surveillance         0750 frigate media   -"
    "d /srv/storage/a/surveillance/clips   0750 frigate media   -"
    "d /srv/storage/a/surveillance/exports 0750 frigate media   -"
  ];

  # ---------------------------------------------------------------------------
  # rclone cloud sync for Frigate clips
  # ---------------------------------------------------------------------------
  # Watches the clips directory and uploads each clip after it is closed.
  # rclone config is in config.age.secrets.rclone-frigate-config.
  systemd.services."frigate-rclone-sync" = {
    description = "Frigate clips cloud sync via rclone";
    after    = [ "podman-frigate.service" "srv-storage-a.mount" ];
    bindsTo  = [ "srv-storage-a.mount" ];
    wantedBy = [ "podman-frigate.service" ];
    path     = [ pkgs.rclone pkgs.inotify-tools ];
    serviceConfig = {
      Type       = "simple";
      User       = "frigate";
      Restart    = "on-failure";
      RestartSec = "15s";
      ExecStart  = pkgs.writeShellScript "frigate-rclone" ''
        CLIPS_DIR=/srv/storage/a/surveillance/clips
        RCLONE_CONF=${config.age.secrets.rclone-frigate-config.path}
        # Upload clips immediately after they close.
        inotifywait -m -e close_write --format "%w%f" "$CLIPS_DIR" | while read path; do
          rclone --config "$RCLONE_CONF" copyto "$path" \
            "EXAMPLE_BUCKET:frigate-clips/$(basename "$path")" \
            --s3-no-check-bucket 2>&1 || true
        done
      '';
    };
  };
}

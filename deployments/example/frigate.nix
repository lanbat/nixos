# deployments/example/frigate.nix
#
# Frigate settings for the example profile (services/frigate.nix documents
# every option): one overhead camera covering a driveway, the pavement and
# the road beyond, with licence plate recognition.
#
# The camera serves HTTP-FLV, the recommended transport for Reolink cameras up
# to 5 MP. go2rtc ingests the main and sub streams once and Frigate reads them
# back from the local restream. Credentials stay in the frigate-rtsp-env
# secret: the sources only name {FRIGATE_RTSP_USER} and {FRIGATE_RTSP_PASSWORD}.
{ config, ... }:

let
  camera = "c1.${config.lanbat.deployment.rootDomain}";
  flv =
    stream:
    "http://${camera}/flv?port=1935&app=bcs&stream=${stream}&user={FRIGATE_RTSP_USER}&password={FRIGATE_RTSP_PASSWORD}";

  vehicles = [
    "person"
    "car"
    "motorcycle"
    "bus"
    "truck"
    "bicycle"
  ];
  animals = [
    "dog"
    "cat"
    "bird"
  ];

  filter = minScore: threshold: { inherit minScore threshold; };
in
{
  lanbat.services.frigate.settings = {
    cameras.c1 = {
      inputs = [
        # Main stream (2560x1920) for detection: the sub stream is too soft
        # for overhead or distant objects.
        {
          stream = "c1";
          source = "ffmpeg:${flv "channel0_main.bcs"}#video=copy#audio=copy#audio=opus";
          roles = [ "detect" ];
        }
        # Sub stream for recording: far smaller than the 5 MP main, so the
        # motion-only rolling window stays bounded. Detection, LPR and zones
        # still run on the main stream.
        {
          stream = "c1_sub";
          source = "ffmpeg:${flv "channel0_ext.bcs"}";
          roles = [ "record" ];
        }
      ];

      detect = {
        width = 1280;
        height = 960;
        # 5 fps is plenty for driveway and road traffic and costs about 30%
        # less detector CPU than 7.
        fps = 5;
        minInitialized = 2;
      };

      lpr = {
        enable = true;
        # Overhead first-storey view: mild enhancement helps OCR without blurring.
        enhancement = 3;
        # Lower than the global default; plates are smaller at driveway distance.
        minArea = 600;
      };

      zones = {
        driveway = {
          coordinates = "0,0.928,0,0.298,0.328,0.124,0.586,0.044,0.712,0.014,0.793,0,1,0,1,1,0.435,1,0.438,0.922,0.012,0.92,0.012,0.978,0.441,0.978,0.433,1,0,1";
          inertia = 3;
          loiteringTime = 0;
        };
        pavement = {
          coordinates = "0.003,0.212,0.183,0.092,0.315,0.024,0.37,0,0,0";
          inertia = 3;
          loiteringTime = 0;
          friendlyName = "Pavement";
        };
        road = {
          coordinates = "0,0,1,0,1,0.22,0,0.22";
          inertia = 3;
          loiteringTime = 0;
          friendlyName = "Tennison Road";
        };
      };

      objects = {
        track = [
          "person"
          "bicycle"
          "car"
          "motorcycle"
          "bus"
          "truck"
        ]
        ++ animals;
        filters = {
          person = filter 0.35 0.45;
          car = filter 0.35 0.45;
          truck = filter 0.35 0.45;
          motorcycle = filter 0.5 0.6;
          bus = filter 0.5 0.65;
          bicycle = filter 0.5 0.65;
          dog = filter 0.45 0.55;
          cat = filter 0.45 0.55;
          bird = filter 0.55 0.65;
        };
      };

      # A long cutoff merges nearby detections into one review item, cutting
      # the per-event snapshot and thumbnail count. Labels are unchanged.
      review = {
        alerts = {
          cutoffTime = 60;
          labels = vehicles;
        };
        detections = {
          cutoffTime = 60;
          labels = vehicles ++ animals;
        };
      };

      # Overhead driveway and distant road traffic need sensitive motion to
      # trigger detection. Do not mask the road.
      motion = {
        threshold = 10;
        contourArea = 5;
      };

      notifications = true;
    };

    # Licence plate recognition: YOLOv9 plate detection and PaddleOCR on
    # detected cars and motorcycles. It needs car/motorcycle in objects.track;
    # do not add license_plate (Frigate+ only). The format matches UK plates.
    extraConfig.lpr = {
      enabled = true;
      detection_threshold = 0.55;
      min_area = 800;
      recognition_threshold = 0.85;
      min_plate_length = 7;
      match_distance = 1;
      format = "^[A-Z]{2}[0-9]{2} ?[A-Z]{3}$";
      debug_save_plates = true;
      replace_rules = [
        {
          pattern = "O";
          replacement = "0";
        }
        {
          pattern = "I";
          replacement = "1";
        }
      ];
    };
  };
}

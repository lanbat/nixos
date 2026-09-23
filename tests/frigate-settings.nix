# tests/frigate-settings.nix
#
# lanbat.services.frigate.settings renders the Frigate config it describes, and
# rejects values Frigate would not accept. Pure evaluation: the derivation only
# builds when every case holds.
{ lib, pkgs }:

let
  evalFrigate =
    settings:
    (lib.nixosSystem {
      modules = [
        ../modules/core/services.nix
        ../modules/wiring/accounts.nix
        ../services/frigate.nix
        {
          boot.isContainer = true;
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "25.11";
          lanbat.services.frigate.settings = settings;
        }
      ];
    }).config;

  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);

  rejects =
    config: !(builtins.tryEval (builtins.deepSeq config.lanbat.frigate.renderedConfig true)).success;

  source = stream: "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@camera.test:554/${stream}";

  twoCameras = {
    cameras = {
      front = {
        inputs = [
          {
            stream = "front";
            source = source "main";
            roles = [ "detect" ];
          }
          {
            stream = "front_sub";
            source = source "sub";
            roles = [ "record" ];
          }
        ];
        detect = {
          width = 1280;
          height = 720;
        };
        zones.path = {
          coordinates = "0,0.5,1,0.5,1,1,0,1";
          friendlyName = "Path";
          inertia = 3;
        };
        objects = {
          track = [ "person" ];
          filters.person.minScore = 0.4;
        };
      };
      back = {
        inputs = [
          {
            stream = "back";
            source = source "back";
            roles = [
              "detect"
              "record"
            ];
          }
        ];
        extraConfig.motion.mask = [ "0,0,0.1,0,0.1,0.1" ];
      };
    };
    retention.motionDays = 3;
    detector.device = "CPU";
    extraConfig.snapshots.retain.default = 5;
  };

  valid = evalFrigate twoCameras;
  rendered = valid.lanbat.frigate.renderedConfig;

  restream = input: {
    path = "rtsp://127.0.0.1:8554/${input}";
    input_args = "preset-rtsp-restream";
  };

  expectedCameras = {
    front = {
      ffmpeg.inputs = [
        (restream "front" // { roles = [ "detect" ]; })
        (restream "front_sub" // { roles = [ "record" ]; })
      ];
      detect = {
        enabled = true;
        width = 1280;
        height = 720;
        fps = 5;
      };
      zones.path = {
        coordinates = "0,0.5,1,0.5,1,1,0,1";
        friendly_name = "Path";
        inertia = 3;
      };
      objects = {
        track = [ "person" ];
        filters.person.min_score = 0.4;
      };
    };
    back = {
      ffmpeg.inputs = [
        (
          restream "back"
          // {
            roles = [
              "detect"
              "record"
            ];
          }
        )
      ];
      detect = {
        enabled = true;
        fps = 5;
      };
      motion.mask = [ "0,0,0.1,0,0.1,0.1" ];
    };
  };

  withCamera =
    camera:
    evalFrigate {
      cameras.bad = {
        inputs = [
          {
            stream = "bad";
            source = source "main";
            roles = [ "detect" ];
          }
        ];
      }
      // camera;
    };

  checks = {
    "cameras render" = rendered.cameras == expectedCameras;
    "streams go through go2rtc" =
      rendered.go2rtc.streams == {
        front = [ (source "main") ];
        front_sub = [ (source "sub") ];
        back = [ (source "back") ];
      };
    "detector device" =
      rendered.detectors.ov == {
        type = "openvino";
        device = "CPU";
      };
    "retention" = rendered.record.motion.days == 3 && rendered.record.alerts.retain.days == 14;
    "extraConfig merges last" =
      rendered.snapshots == {
        enabled = true;
        retain.default = 5;
      };
    "no broker, no mqtt" = rendered.mqtt == { enabled = false; };
    "semantic search stays off" = !rendered.semantic_search.enabled;
    "valid config passes its assertions" = failedAssertions valid == [ ];

    "malformed zone coordinates are rejected" = rejects (withCamera {
      zones.z.coordinates = "0,0,1,1";
    });
    "an unknown input role is rejected" = rejects (evalFrigate {
      cameras.bad.inputs = [
        {
          stream = "bad";
          source = source "main";
          roles = [ "detection" ];
        }
      ];
    });
    "a score above 1 is rejected" = rejects (withCamera {
      objects.filters.person.threshold = 1.5;
    });
    "a camera without a detect input fails" =
      failedAssertions (evalFrigate {
        cameras.bad.inputs = [
          {
            stream = "bad";
            source = source "main";
            roles = [ "record" ];
          }
        ];
      }) == [ "lanbat.services.frigate: camera bad needs exactly one input with the detect role." ];
    "a stream name used twice fails" =
      lib.any (lib.hasInfix "stream names used more than once: front")
        (
          failedAssertions (evalFrigate {
            cameras = twoCameras.cameras // {
              back.inputs = [
                {
                  stream = "front";
                  source = source "back";
                  roles = [ "detect" ];
                }
              ];
            };
          })
        );
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
if failed != [ ] then
  throw "frigate-settings: failed: ${lib.concatStringsSep "; " failed}; rendered cameras: ${builtins.toJSON rendered.cameras}"
else
  pkgs.runCommand "frigate-settings" { } ''
    echo ${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.attrNames checks))} > $out
  ''

# Wyoming voice satellite backend (modules/core/voice-satellite.nix).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.lanbat.voiceSatellite;
  alsa = pkgs.alsa-utils;
  coreutils = pkgs.coreutils;
  webrtcNoiseGain = pkgs.python3Packages.webrtc-noise-gain;
  webrtcFixedUpstream = (webrtcNoiseGain.patches or [ ]) != [ ];
  satellitePackage =
    if webrtcFixedUpstream then
      pkgs.wyoming-satellite
    else
      pkgs.wyoming-satellite.overridePythonAttrs (old: {
        optional-dependencies = old.optional-dependencies // {
          webrtc = [
            (webrtcNoiseGain.overridePythonAttrs (webrtcOld: {
              env = (webrtcOld.env or { }) // {
                NIX_CFLAGS_COMPILE = toString [
                  (webrtcOld.env.NIX_CFLAGS_COMPILE or "")
                  "-include stdint.h"
                ];
              };
            }))
          ];
        };
      });

  vendor = lib.head (lib.splitString ":" cfg.microphone.usbId);
  product = lib.last (lib.splitString ":" cfg.microphone.usbId);

  micCommand = pkgs.writeShellScript "voice-satellite-mic" ''
    find_card() {
      local card
      for card in /sys/class/sound/card*; do
        [[ -r $card/device/../idVendor && -r $card/device/../idProduct ]] || continue
        if [[ $(<"$card/device/../idVendor") == ${vendor} && $(<"$card/device/../idProduct") == ${product} ]]; then
          cardNumber=$(<"$card/number")
          return 0
        fi
      done
      return 1
    }
    announced=
    until find_card; do
      if [[ -z $announced ]]; then
        echo "voice-satellite: waiting for a sound card with USB ID ${cfg.microphone.usbId}" >&2
        announced=1
      fi
      ${coreutils}/bin/sleep 3
    done
    exec ${alsa}/bin/arecord -D "plughw:$cardNumber,0" -r 16000 -c 1 -f S16_LE -t raw -q
  '';

  runtimeDir = "/run/voice-satellite";
  announced = "${runtimeDir}/announced";

  replyCommand = pkgs.writeShellScript "voice-satellite-reply" ''
    ${coreutils}/bin/rm -f ${announced}
    message=$(${coreutils}/bin/cat)
    [[ -n $message ]] || exit 0
    if [[ "${toString cfg.alwaysPlayLocally}" == "1" ]]; then
      exit 0
    fi
    if [[ ! -s ${runtimeDir}/ha-token ]]; then
      echo "voice-satellite: no Home Assistant token (ha-voice-token.age), playing the reply here" >&2
      exit 0
    fi
    (umask 077 && printf 'Authorization: Bearer %s\n' "$(<${runtimeDir}/ha-token)" > ${runtimeDir}/auth-header)
    body=$(${lib.getExe pkgs.jq} -n --arg message "$message" --arg room ${lib.escapeShellArg cfg.room} \
      '{message: $message, room: $room}')
    if ! response=$(${lib.getExe pkgs.curl} -sS --fail --max-time 5 \
      ${lib.optionalString (cfg.homeAssistant.caFile != null) "--cacert ${cfg.homeAssistant.caFile}"} \
      -H @${runtimeDir}/auth-header -H 'Content-Type: application/json' --data "$body" \
      '${cfg.homeAssistant.url}/api/services/script/voice_reply?return_response'); then
      echo "voice-satellite: Home Assistant didn't take the reply, playing it here" >&2
      exit 0
    fi
    players=$(${lib.getExe pkgs.jq} -r '.service_response.players // 0' <<<"$response")
    if (( players > 0 )); then
      : > ${announced}
    fi
  '';

  soundCommand = pkgs.writeShellScript "voice-satellite-play" ''
    if [[ -e ${announced} ]]; then
      ${coreutils}/bin/rm -f ${announced}
      exec ${coreutils}/bin/cat > /dev/null
    fi
    exec ${alsa}/bin/aplay -D ${cfg.speaker} -r 22050 -c 1 -f S16_LE -t raw -q
  '';
in
{
  config = lib.mkIf (cfg.enable && cfg.backend == "wyoming") {
    users.groups.wyoming-satellite = { };
    users.users.wyoming-satellite = {
      isSystemUser = true;
      group = "wyoming-satellite";
    };

    services.wyoming.satellite = {
      enable = true;
      package = satellitePackage;
      inherit (cfg) name uri;
      user = "wyoming-satellite";
      group = "wyoming-satellite";
      microphone = {
        command = "${micCommand}";
        autoGain = 0;
        noiseSuppression = 0;
      };
      vad.enable = false;
      sound.command = "${soundCommand}";
      extraArgs =
        lib.optionals (cfg.microphone.volumeMultiplier != 1.0) [
          "--mic-volume-multiplier"
          (toString cfg.microphone.volumeMultiplier)
        ]
        ++ lib.optionals (cfg.room != null && !cfg.alwaysPlayLocally) [
          "--synthesize-command"
          "${replyCommand}"
        ]
        ++ lib.optionals (cfg.awakeSound != null) [
          "--awake-wav"
          cfg.awakeSound
        ];
    };

    systemd.services.wyoming-satellite.serviceConfig = {
      PrivateDevices = lib.mkForce false;
      DeviceAllow = lib.mkForce [ "char-alsa rw" ];
      ExecStartPre =
        map (args: "-+${alsa}/bin/amixer -q ${lib.replaceStrings [ "%" ] [ "%%" ] args}") cfg.mixer
        ++
          lib.optional (cfg.room != null)
            "-+${coreutils}/bin/install -m 0400 -o wyoming-satellite -g wyoming-satellite ${config.lanbat.secrets.ha-voice-token.path} ${runtimeDir}/ha-token";
      RuntimeDirectory = "voice-satellite";
      RuntimeDirectoryMode = "0700";
    };
  };
}

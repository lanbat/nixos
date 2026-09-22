# modules/core/voice-satellite.nix
#
# Wyoming voice satellite: a microphone and a speaker for Home Assistant's
# Assist, on either host. HA on the server connects to it, runs the audio
# through the "Voice" pipeline (wake word, speech-to-text, conversation agent,
# text-to-speech; services/wyoming.nix and services/home-assistant.nix) and
# sends the spoken reply back.
#
# Microphone
# ----------
# Found by its USB ID each time capture starts, so its ALSA card number
# doesn't matter and it can be unplugged and plugged back in. The default is
# the PlayStation Eye, a webcam with a 4-microphone array.
#
# Speaker
# -------
# Replies play to an ALSA device. A hardware device plays nothing else at the
# same time; the Pi plays replies through its PipeWire instead, which mixes
# them with Snapcast and the TV (modules/pi/audio.nix).
#
# Replies in the room
# -------------------
# A satellite with a room (lanbat.voiceRooms) hands each reply to Home
# Assistant's voice_reply script (services/home-assistant.nix), which speaks
# it as an announcement on the Music Assistant players in that area; Music
# Assistant turns their music down meanwhile. The satellite then skips its
# own copy, so a satellite that is also a Snapcast speaker (the Pi) doesn't
# say it twice. With no players in the room, or Home Assistant out of reach,
# the reply plays on the satellite's speaker.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;

  cfg = config.lanbat.voiceSatellite;
  alsa = pkgs.alsa-utils;
  coreutils = pkgs.coreutils;
  # The module always adds webrtc-noise-gain, for auto gain and noise
  # suppression. Its bundled WebRTC code uses uint32_t without including
  # <cstdint>, which GCC 15 rejects on x86_64. stdint.h, because the flags
  # reach its C files too.
  webrtcNoiseGain = pkgs.python3Packages.webrtc-noise-gain.overridePythonAttrs (old: {
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = toString [
        (old.env.NIX_CFLAGS_COMPILE or "")
        "-include stdint.h"
      ];
    };
  });

  vendor = lib.head (lib.splitString ":" cfg.microphone.usbId);
  product = lib.last (lib.splitString ":" cfg.microphone.usbId);

  # 16 kHz mono, which Wyoming's speech-to-text expects. Bash builtins only,
  # so it doesn't depend on the unit's PATH.
  micCommand = pkgs.writeShellScript "voice-satellite-mic" ''
    for card in /sys/class/sound/card*; do
      [[ -r $card/device/../idVendor && -r $card/device/../idProduct ]] || continue
      if [[ $(<"$card/device/../idVendor") == ${vendor} && $(<"$card/device/../idProduct") == ${product} ]]; then
        exec ${alsa}/bin/arecord -D "plughw:$(<"$card/number"),0" -r 16000 -c 1 -f S16_LE -t raw -q
      fi
    done
    echo "voice-satellite: no sound card with USB ID ${cfg.microphone.usbId}" >&2
    exit 1
  '';

  runtimeDir = "/run/voice-satellite";
  # Present while the room's speakers announce the current reply.
  announced = "${runtimeDir}/announced";

  # Runs for each reply, with its text on stdin, before its audio arrives.
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
    # A header file, not an argument, keeps the token out of the process list.
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

  # Plays a reply, unless the room's speakers announce it. The satellite starts
  # this for each reply.
  soundCommand = pkgs.writeShellScript "voice-satellite-play" ''
    if [[ -e ${announced} ]]; then
      ${coreutils}/bin/rm -f ${announced}
      exec ${coreutils}/bin/cat > /dev/null
    fi
    # piper's replies are 22.05 kHz mono.
    exec ${alsa}/bin/aplay -D ${cfg.speaker} -r 22050 -c 1 -f S16_LE -t raw -q
  '';
in
{
  options.lanbat.voiceSatellite = {
    enable = lib.mkEnableOption "a Wyoming voice satellite for Home Assistant";

    name = mkOption {
      type = types.str;
      example = "Kitchen";
      description = "Name of the satellite's device in Home Assistant.";
    };

    uri = mkOption {
      type = types.str;
      example = "tcp://0.0.0.0:10700";
      description = "Address the satellite listens on. Home Assistant connects to it.";
    };

    microphone.usbId = mkOption {
      type = types.strMatching "[0-9a-f]{4}:[0-9a-f]{4}";
      default = "1415:2000";
      description = "USB vendor:product ID of the microphone, as lsusb shows it. The default is the PlayStation Eye.";
    };

    speaker = mkOption {
      type = types.str;
      example = "plughw:CARD=PCH,DEV=0";
      description = "ALSA device that plays the replies. aplay -L lists them.";
    };

    mixer = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "-c PCH sset Master 80% unmute" ];
      description = "amixer arguments applied before the satellite starts, for example to unmute the speaker.";
    };

    room = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "Living Room";
      description = ''
        Home Assistant area the satellite is in. Its replies then play on the
        area's Music Assistant players, and on its own speaker only when the
        area has none.
      '';
    };

    alwaysPlayLocally = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Play the pipeline's Piper audio on this satellite immediately, instead
        of handing the reply to Home Assistant's voice_reply script for Music
        Assistant room speakers. Skips an HTTPS round trip and a second TTS
        pass, which cuts perceived latency.
      '';
    };

    awakeSound = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/nix/store/…-voice-satellite-awake-chime/awake.wav";
      description = ''
        WAV file played on the speaker when Home Assistant detects the wake word
        (wyoming-satellite --awake-wav). Use a short clip (~0.2 s) at 22.05 kHz
        mono so the mic is not muted for long before command capture.
      '';
    };

    homeAssistant = {
      url = mkOption {
        type = types.str;
        example = "https://ha.example.com";
        description = "Home Assistant's address, for handing replies to the room's speakers.";
      };

      caFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "CA certificate of Home Assistant's HTTPS address, when a public CA didn't issue it.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.wyoming-satellite = { };
    users.users.wyoming-satellite = {
      isSystemUser = true;
      group = "wyoming-satellite";
    };

    # The satellites' Home Assistant token: a long-lived access token of a
    # Home Assistant user, copied for the satellite when it starts.
    lanbat.services.voice-satellite.secrets = lib.mkIf (cfg.room != null) {
      ha-voice-token.owner = "root";
    };

    # The satellite listens and Home Assistant connects to it, so the satellite
    # is the provider of this edge. The port comes from cfg.uri rather than a
    # literal, the same way services/home-assistant.nix reads it.
    lanbat.services.voice-satellite.endpoint = {
      scheme = "tcp";
      port = lib.toInt (lib.last (lib.splitString ":" cfg.uri));
    };

    services.wyoming.satellite = {
      enable = true;
      package = pkgs.wyoming-satellite.overridePythonAttrs (old: {
        optional-dependencies = old.optional-dependencies // {
          webrtc = [ webrtcNoiseGain ];
        };
      });
      inherit (cfg) name uri;
      user = "wyoming-satellite";
      group = "wyoming-satellite";
      microphone = {
        command = "${micCommand}";
        # Home Assistant runs its own VAD and optional noise processing on the
        # stream; satellite-side WebRTC gain/suppression adds latency only.
        autoGain = 0;
        noiseSuppression = 0;
      };
      # Home Assistant detects the wake word, so the satellite streams all the
      # time. Its own VAD can't run here anyway: pysilero-vad takes 512-sample
      # chunks only, and the webrtc processing re-chunks the audio.
      vad.enable = false;
      sound.command = "${soundCommand}";
      extraArgs =
        lib.optionals (cfg.room != null && !cfg.alwaysPlayLocally) [
          "--synthesize-command"
          "${replyCommand}"
        ]
        ++ lib.optionals (cfg.awakeSound != null) [
          "--awake-wav"
          cfg.awakeSound
        ];
    };

    systemd.services.wyoming-satellite.serviceConfig = {
      # The module hides /dev, expecting PulseAudio or PipeWire; this satellite
      # uses the ALSA devices directly.
      PrivateDevices = lib.mkForce false;
      DeviceAllow = lib.mkForce [ "char-alsa rw" ];
      # As root (+). A missing card, or a missing token, doesn't stop the
      # satellite (-); without the token, replies play on its own speaker.
      # systemd reads % as a specifier.
      ExecStartPre =
        map (args: "-+${alsa}/bin/amixer -q ${lib.replaceStrings [ "%" ] [ "%%" ] args}") cfg.mixer
        ++
          lib.optional (cfg.room != null)
            "-+${coreutils}/bin/install -m 0400 -o wyoming-satellite -g wyoming-satellite ${config.age.secrets.ha-voice-token.path} ${runtimeDir}/ha-token";
      RuntimeDirectory = "voice-satellite";
      RuntimeDirectoryMode = "0700";
    };
  };
}

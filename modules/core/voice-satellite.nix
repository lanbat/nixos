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
# Replies play straight to an ALSA device. While another program holds the
# same device (Snapcast's client while music plays, or the TV frontend's
# PipeWire), a reply can't play.
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
  };

  config = lib.mkIf cfg.enable {
    users.groups.wyoming-satellite = { };
    users.users.wyoming-satellite = {
      isSystemUser = true;
      group = "wyoming-satellite";
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
      microphone.command = "${micCommand}";
      # piper's replies are 22.05 kHz mono.
      sound.command = "${alsa}/bin/aplay -D ${cfg.speaker} -r 22050 -c 1 -f S16_LE -t raw -q";
    };

    systemd.services.wyoming-satellite.serviceConfig = {
      # The module hides /dev, expecting PulseAudio or PipeWire; this satellite
      # uses the ALSA devices directly.
      PrivateDevices = lib.mkForce false;
      DeviceAllow = lib.mkForce [ "char-alsa rw" ];
      # As root (+), and a missing card doesn't stop the satellite (-). systemd
      # reads % as a specifier.
      ExecStartPre = map (
        args: "-+${alsa}/bin/amixer -q ${lib.replaceStrings [ "%" ] [ "%%" ] args}"
      ) cfg.mixer;
    };
  };
}

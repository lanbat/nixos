# modules/pi/audio.nix
#
# One PipeWire for the whole Pi, owning the HDMI output.
#
# Snapcast's client, the voice satellite and the TV sessions all play through
# it. The HDMI device only takes IEC958 frames, so ALSA's own mixing (dmix)
# can't share it; without a sound server, whichever program opened it first
# kept the others out, and a spoken reply failed while music played.
#
# The system-wide instance listens on /run/pipewire/pipewire-0 and, for
# PulseAudio clients, /run/pulse/native. Clients need the pipewire group.
#
# Voice satellite
# ---------------
# Replies play through PipeWire, so they mix with the music. While the
# assistant listens and answers, Snapcast's volume drops, which also keeps
# the music from drowning out the speaker in the microphone. The microphone
# stays a direct ALSA capture: WirePlumber leaves that device alone.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  satellite = config.lanbat.voiceSatellite;
  runtimeDir = "/run/pipewire";

  # Sets the volume of Snapcast's client streams in PipeWire.
  snapcastVolume =
    name: volume:
    pkgs.writeShellScript "snapcast-${name}" ''
      export PIPEWIRE_RUNTIME_DIR=${runtimeDir}
      ids=$(${config.services.pipewire.package}/bin/pw-dump | ${lib.getExe pkgs.jq} -r '
        .[]
        | select(.type == "PipeWire:Interface:Node"
            and .info.props["application.process.binary"] == "snapclient")
        | .id')
      for id in $ids; do
        ${config.services.pipewire.wireplumber.package}/bin/wpctl set-volume "$id" ${volume}
      done
    '';
  duck = snapcastVolume "duck" "0.25";
  restore = snapcastVolume "restore" "1.0";

  usbId = lib.splitString ":" satellite.microphone.usbId;
in
{
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    systemWide = true;
    alsa.enable = true;
    pulse.enable = true;

    wireplumber.extraConfig."51-voice-satellite-microphone" = lib.mkIf satellite.enable {
      "monitor.alsa.rules" = [
        {
          matches = [
            {
              "device.vendor.id" = "0x${lib.head usbId}";
              "device.product.id" = "0x${lib.last usbId}";
            }
          ];
          actions.update-props."device.disabled" = true;
        }
      ];
    };
  };

  # For login sessions (the TV sessions).
  environment.sessionVariables = {
    PIPEWIRE_RUNTIME_DIR = runtimeDir;
    PULSE_SERVER = "unix:/run/pulse/native";
  };

  lanbat.voiceSatellite.speaker = "pipewire";

  services.wyoming.satellite.extraArgs = lib.mkIf satellite.enable [
    # Home Assistant heard the wake word.
    "--detection-command"
    "${duck}"
    "--tts-played-command"
    "${restore}"
    "--error-command"
    "${restore}"
    "--disconnected-command"
    "${restore}"
    "--startup-command"
    "${restore}"
  ];

  systemd.services.wyoming-satellite = lib.mkIf satellite.enable {
    environment.PIPEWIRE_RUNTIME_DIR = runtimeDir;
    serviceConfig.SupplementaryGroups = [ "pipewire" ];
  };
}

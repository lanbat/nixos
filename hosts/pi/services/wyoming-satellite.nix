# hosts/pi/services/wyoming-satellite.nix
#
# Wyoming satellite — captures mic audio and plays back TTS responses.
#
# The satellite is the voice-hardware endpoint of Home Assistant's Wyoming
# voice assistant pipeline.  It runs on the Pi so that the microphone and
# speaker are local to the room, while all heavy processing (STT, TTS, intent
# recognition) happens on the server.
#
# Audio
# -----
# The satellite uses ALSA directly (arecord/aplay) for both microphone input
# and TTS playback, bypassing PulseAudio.  This keeps it completely independent
# of Snapcast: Snapcast handles music through PulseAudio, while the satellite
# handles voice through the ALSA hardware device.
#
# The satellite service user is added to the "audio" group so it can access
# ALSA devices.
#
# Microphone device
# -----------------
# The default ALSA capture device is used.  If you have multiple audio
# devices (e.g. USB mic + HDMI), you may need to specify the device
# explicitly.  Find your mic with:
#
#   arecord -l          # list capture devices
#   arecord -D hw:1,0 ... # use card 1, device 0
#
# Set MIC_DEVICE and SPK_DEVICE in the service below if the defaults are wrong.
#
# Snapcast coexistence
# --------------------
# Snapcast (snapclient) runs through PulseAudio for music playback.
# The satellite runs through ALSA for voice.  Both can be active simultaneously:
#
#   Music playback → snapclient → PulseAudio → hardware sink
#   Voice TTS      → satellite → ALSA (aplay) → hardware sink
#
# If the hardware sink is the same device, PulseAudio and ALSA will fight for
# exclusive access.  To avoid this:
#   - Use a USB microphone for capture (avoids conflict entirely).
#   - Or use the PulseAudio ALSA plugin (default on most systems): arecord and
#     aplay route through PulseAudio automatically when the ALSA plug device is
#     configured as default.
#   - Or configure a separate audio output for TTS (e.g. 3.5mm jack vs HDMI).
#
# Firewall
# --------
# Port 10700 (TCP) is opened in hosts/pi/default.nix, restricted to the
# server's IP.  HA (on the server) connects outbound to Pi:10700.
#
# Post-install
# ------------
# See docs/deployment-checklist.md § Wyoming Voice Assistant.
{ config, pkgs, lib, ... }:

{
  services.wyoming.satellite = {
    enable = true;
    name   = "Pi Satellite";
    uri    = "tcp://0.0.0.0:10700";

    # Microphone: 16 kHz mono S16LE — required by the Wyoming STT pipeline.
    microphone.command = [
      "${pkgs.alsa-utils}/bin/arecord"
      "-D" "default"
      "-r" "16000"
      "-c" "1"
      "-f" "S16_LE"
      "-t" "raw"
      "-q"
    ];

    # Speaker: TTS responses arrive as 22050 Hz mono S16LE from piper.
    sound = {
      enable  = true;
      command = [
        "${pkgs.alsa-utils}/bin/aplay"
        "-D" "default"
        "-r" "22050"
        "-c" "1"
        "-f" "S16_LE"
        "-t" "raw"
        "-q"
      ];
    };
  };

  # Give the satellite service user access to ALSA audio devices.
  users.users.wyoming-satellite.extraGroups = [ "audio" ];
}

# pkgs/voice-satellite-awake-chime/default.nix
#
# Short two-tone chime for wyoming-satellite --awake-wav (22.05 kHz mono, matches Piper).
#
# The satellite mutes its microphone for the length of this file (plus 0.5 s)
# while it plays. The chime reaches the room a moment after playback starts and
# rings on, so the trailing silence keeps the microphone muted until it has
# died away: otherwise the assistant hears the chime as speech and ends the
# command before the user has said anything.
{
  pkgs,
}:

pkgs.runCommand "voice-satellite-awake-chime"
  {
    nativeBuildInputs = [ pkgs.sox ];
  }
  ''
    mkdir -p $out
    ${pkgs.sox}/bin/sox -r 22050 -c 1 -b 16 -n $out/awake.wav \
      synth 0.08 sine 880 vol 0.35 \
      synth 0.12 sine 1175 vol 0.3 \
      fade 0.01 0.2 0.06 \
      pad 0 0.5
  ''

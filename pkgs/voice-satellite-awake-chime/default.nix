# pkgs/voice-satellite-awake-chime/default.nix
#
# Short two-tone chime for wyoming-satellite --awake-wav (22.05 kHz mono, matches Piper).
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
      fade 0.01 0.2 0.06
  ''

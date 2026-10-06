# pkgs/lva-wakeup-chime/default.nix
#
# Short wake chime for Linux Voice Assistant (--wakeup-sound). No trailing
# silence: with --listen-during-wake-sound and echo cancellation the mic stays
# open while the chime plays.
{
  pkgs,
}:

pkgs.runCommand "lva-wakeup-chime"
  {
    nativeBuildInputs = [ pkgs.sox ];
  }
  ''
    mkdir -p $out
    ${pkgs.sox}/bin/sox -r 22050 -c 1 -b 16 -n $out/wakeup.flac \
      synth 0.08 sine 880 vol 0.35 \
      synth 0.12 sine 1175 vol 0.3 \
      fade 0.01 0.2 0.06
  ''

# pkgs/hey-nabu-wakeword-model/default.nix
#
# Custom "hey nabu" wake word for wyoming-openwakeword.
# Source: https://github.com/fwartner/home-assistant-wakewords-collection
{
  pkgs ? import <nixpkgs> { },
}:

pkgs.runCommand "hey-nabu-wakeword-model" { } ''
  mkdir -p $out
  cp ${
    pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/fwartner/home-assistant-wakewords-collection/main/en/hey_nabu/hey_nabu_v2.tflite";
      hash = "sha256-zhi2nhvd+1bnD+c51soPQj9wpucQ8Fs3a69qNiVokjQ=";
    }
  } $out/hey_nabu.tflite
  # Must be hey_nabu.tflite (not hey_nabu_v2): openwakeword only strips _vN
  # suffixes when the base name has no underscores, so _v2 would register as
  # hey_nabu_v2 while HA's pipeline uses wake_word_id hey_nabu.
''

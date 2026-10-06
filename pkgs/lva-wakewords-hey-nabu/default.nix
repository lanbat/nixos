# pkgs/lva-wakewords-hey-nabu/default.nix
#
# openWakeWord "hey nabu" for Linux Voice Assistant (--wake-word-dir).
# Same v2 model as the Wyoming pipeline (pkgs/hey-nabu-wakeword-model).
{
  pkgs,
}:

let
  model = pkgs.callPackage ../hey-nabu-wakeword-model { };
in
pkgs.runCommand "lva-wakewords-hey-nabu" { } ''
  mkdir -p $out
  cp ${model}/hey_nabu.tflite $out/hey_nabu.tflite
  cat > $out/hey_nabu.json <<'EOF'
  {
    "type": "openWakeWord",
    "wake_word": "Hey Nabu",
    "model": "hey_nabu.tflite",
    "trained_languages": ["en"],
    "openWakeWord": {
      "probability_cutoff": 0.35
    }
  }
  EOF
''

# pkgs/voice-id/default.nix
#
# voice-id: the Wyoming speech-to-text proxy that speaker identification sits
# in (services/voice-id.nix). Phase A: pass-through to faster-whisper.
{
  python3Packages,
}:

python3Packages.buildPythonApplication {
  pname = "voice-id";
  version = "0.1";
  format = "other";
  src = ./.;
  dontBuild = true;
  installPhase = ''
    install -Dm755 voice_id.py $out/bin/voice-id
  '';
  dependencies = [ python3Packages.wyoming ];
  doCheck = false;
  meta = {
    description = "Wyoming speech-to-text proxy for speaker identification";
    mainProgram = "voice-id";
  };
}

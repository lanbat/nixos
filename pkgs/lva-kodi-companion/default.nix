# pkgs/lva-kodi-companion/default.nix
{
  lib,
  python3Packages,
}:

python3Packages.buildPythonApplication {
  pname = "lva-kodi-companion";
  version = "1.0";
  format = "other";
  src = ./.;
  dontBuild = true;
  installPhase = ''
    install -Dm755 companion.py $out/bin/lva-kodi-companion
  '';
  dependencies = [ python3Packages.websockets ];
  doCheck = false;
  meta = {
    description = "Pause Kodi video, show captions and switch the TV over CEC for a Linux Voice Assistant satellite";
    mainProgram = "lva-kodi-companion";
  };
}

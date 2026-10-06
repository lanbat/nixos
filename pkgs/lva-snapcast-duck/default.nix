# pkgs/lva-snapcast-duck/default.nix
{
  lib,
  python3Packages,
}:

python3Packages.buildPythonApplication {
  pname = "lva-snapcast-duck";
  version = "1.0";
  format = "other";
  src = ./.;
  dontBuild = true;
  installPhase = ''
    install -Dm755 duck.py $out/bin/lva-snapcast-duck
  '';
  dependencies = [ python3Packages.websockets ];
  doCheck = false;
  meta = {
    description = "Duck Snapcast streams while Linux Voice Assistant is active";
    mainProgram = "lva-snapcast-duck";
  };
}

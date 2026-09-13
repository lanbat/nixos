{
  pkgs,
}:

let
  setupScript = ./setup-ma.py;
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.aiohttp
    ps.music-assistant-client
  ]);
in
pkgs.writeShellScriptBin "music-assistant-setup" ''
  exec ${pythonEnv}/bin/python3 ${setupScript}
''

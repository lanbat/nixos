{
  pkgs,
}:

let
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.aiohttp
    ps.music-assistant-client
    ps.music-assistant-models
    ps.radios # RadioBrowser lookups by country, as Music Assistant's provider does
  ]);
in
pkgs.writeShellScriptBin "music-assistant-sources" ''
  exec ${pythonEnv}/bin/python3 ${./sources.py} "$@"
''

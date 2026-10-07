# pkgs/home-assistant-dashboards/default.nix
{
  lib,
  python3,
  runCommand,
}:

runCommand "home-assistant-dashboards"
  {
    meta = {
      description = "Generate Home Assistant dashboards from its device, entity and area registries";
      mainProgram = "home-assistant-dashboards";
    };
  }
  ''
    install -Dm755 ${./generate.py} $out/bin/home-assistant-dashboards
    substituteInPlace $out/bin/home-assistant-dashboards \
      --replace-fail "#!/usr/bin/env python3" "#!${lib.getExe python3}"
  ''

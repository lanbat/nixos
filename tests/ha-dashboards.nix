# tests/ha-dashboards.nix
#
# The dashboard generator (pkgs/home-assistant-dashboards) on a made-up home:
# see tests/ha-dashboards.py for what is checked.
{ pkgs }:

let
  generator = pkgs.callPackage ../pkgs/home-assistant-dashboards { };
in
pkgs.runCommand "ha-dashboards-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./ha-dashboards.py} ${generator}/bin/home-assistant-dashboards
  touch $out
''

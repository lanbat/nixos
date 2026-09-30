# tests/on-demand-activator.nix
#
# The on-demand activator's own tests (pkgs/on-demand-activator), against a
# local fake service: plain requests are proxied, and a WebSocket upgrade is
# tunnelled both ways and keeps the idle stamp fresh.
{ pkgs }:

pkgs.runCommand "on-demand-activator-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  cp ${../pkgs/on-demand-activator}/*.py .
  python3 -m unittest -v test_activator
  touch $out
''

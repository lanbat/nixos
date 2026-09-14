# pkgs/grafana-dashboards/default.nix
#
# Declarative Grafana dashboards for Telegraf → InfluxDB metrics.
# Generated from build.py and provisioned by services/grafana.nix.
{
  lib,
  python3,
  stdenvNoCC,
}:

let
  dashboards = stdenvNoCC.mkDerivation {
    pname = "grafana-dashboards";
    version = "2";

    src = ./.;

    nativeBuildInputs = [ python3 ];

    installPhase = ''
      runHook preInstall
      ${python3}/bin/python3 ./build.py
      mkdir -p $out
      cp homelab-*.json $out/
      runHook postInstall
    '';

    meta.description = "Homelab Grafana dashboards for Telegraf system metrics";
  };
in
dashboards

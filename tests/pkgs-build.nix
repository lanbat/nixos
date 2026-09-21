# tests/pkgs-build.nix
#
# Build custom derivations under pkgs/ so CI catches packaging errors before deploy.
{ pkgs }:

let
  domain = "home.example.com";
  scripts = pkgs.callPackage ../pkgs/scripts { inherit domain; };
  pages = pkgs.callPackage ../pkgs/service-unavailable-page { inherit domain; };
  caPage = pkgs.callPackage ../pkgs/ca-landing-page { };
  dashboards = pkgs.callPackage ../pkgs/grafana-dashboards { };
  kodiTvConfig = pkgs.callPackage ../pkgs/kodi-tv-config { };
  kodiBootstrap = pkgs.callPackage ../pkgs/kodi-bootstrap { };
  androidProvision = pkgs.callPackage ../pkgs/android-provision { };
in
pkgs.runCommand "pkgs-build-smoke"
  {
    nativeBuildInputs = [
      scripts
      pages
      caPage
      dashboards
      kodiBootstrap
      androidProvision
    ];
  }
  ''
    command -v backup-server
    command -v quota-setup
    command -v kodi-bootstrap
    command -v android-provision
    test -f ${pages}/offline.html
    test -f ${caPage}/index.html
    test -d ${dashboards}
    test -f ${kodiTvConfig}/sources.xml
    touch $out
  ''

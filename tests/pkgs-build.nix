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
in
pkgs.runCommand "pkgs-build-smoke"
  {
    nativeBuildInputs = [
      scripts
      pages
      caPage
      dashboards
    ];
  }
  ''
    command -v backup-server
    command -v quota-setup
    test -f ${pages}/offline.html
    test -f ${caPage}/index.html
    test -d ${dashboards}
    touch $out
  ''

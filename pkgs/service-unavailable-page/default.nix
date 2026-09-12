# pkgs/service-unavailable-page/default.nix
#
# Static pages served by Caddy when a reverse-proxied backend is down.
{
  pkgs ? import <nixpkgs> { },
  domain,
}:

pkgs.runCommand "service-unavailable-page"
  {
    inherit domain;
  }
  ''
    mkdir -p $out
    substitute ${./offline.html} $out/offline.html --replace-fail '@domain@' "$domain"
    substitute ${./storage.html} $out/storage.html --replace-fail '@domain@' "$domain"
  ''

# pkgs/ca-landing-page/default.nix
#
# Static files for the CA trust landing page at ca.&lt;domain&gt;.
# The actual CA cert (root.crt) is copied here at runtime by the
# caddy-export-ca systemd service in hosts/server/services/caddy.nix.
{ pkgs ? import <nixpkgs> {} }:

pkgs.stdenv.mkDerivation {
  pname   = "ca-landing-page";
  version = "1.0.0";

  src = ./.;

  installPhase = ''
    install -Dm644 ${./index.html} $out/index.html
  '';

  meta.description = "CA trust distribution landing page";
}

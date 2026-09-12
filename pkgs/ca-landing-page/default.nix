# pkgs/ca-landing-page/default.nix
#
# Static files for the CA trust landing page at ca.&lt;domain&gt;.
# The actual CA cert (root.crt) is copied here at runtime by the
# caddy-export-ca systemd service in services/caddy.nix.
{
  pkgs ? import <nixpkgs> { },
  caRootCert ? ../../secrets/caddy-ca-root.crt,
}:

pkgs.stdenv.mkDerivation {
  pname = "ca-landing-page";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.openssl ];

  installPhase = ''
    mkdir -p $out
    fingerprint=$(${pkgs.openssl}/bin/openssl x509 -in ${caRootCert} -noout -fingerprint -sha256 \
      | sed 's/sha256 Fingerprint=//')
    sed "s|PLACEHOLDER_SHA256_FINGERPRINT|$fingerprint|" ${./index.html} > $out/index.html
  '';

  meta.description = "CA trust distribution landing page";
}

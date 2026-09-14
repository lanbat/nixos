{
  lib,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "chiaki-tv-config";
  version = "1.0";

  src = ./.;

  installPhase = ''
    install -Dm644 Chiaki.conf $out/Chiaki.conf
  '';

  meta.description = "Seeded chiaki-ng settings for the Pi TV frontend";
}

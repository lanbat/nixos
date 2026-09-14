{
  lib,
  stdenv,
  makeWrapper,
  coreutils,
  util-linux,
  sqlite,
  curl,
  unzip,
}:

stdenv.mkDerivation {
  pname = "kodi-bootstrap";
  version = "1.0";

  src = ./bootstrap-kodi.sh;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    install -Dm755 $src $out/bin/kodi-bootstrap
    wrapProgram $out/bin/kodi-bootstrap \
      --prefix PATH : "${lib.makeBinPath [
        coreutils
        util-linux
        sqlite
        curl
        unzip
      ]}"
  '';
}

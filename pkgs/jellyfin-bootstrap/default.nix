{
  lib,
  stdenv,
  makeWrapper,
  curl,
  jq,
}:

stdenv.mkDerivation {
  pname = "jellyfin-bootstrap";
  version = "1.0";

  src = ./bootstrap-jellyfin.sh;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    install -Dm755 $src $out/bin/jellyfin-bootstrap
    wrapProgram $out/bin/jellyfin-bootstrap \
      --prefix PATH : "${
        lib.makeBinPath [
          curl
          jq
        ]
      }"
  '';
}

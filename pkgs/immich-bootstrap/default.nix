{
  lib,
  stdenv,
  makeWrapper,
  curl,
  jq,
}:

stdenv.mkDerivation {
  pname = "immich-bootstrap";
  version = "1.0";

  src = ./bootstrap-immich.sh;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    install -Dm755 $src $out/bin/immich-bootstrap
    wrapProgram $out/bin/immich-bootstrap \
      --prefix PATH : "${
        lib.makeBinPath [
          curl
          jq
        ]
      }"
  '';
}

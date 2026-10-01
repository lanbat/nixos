{
  lib,
  stdenv,
  makeWrapper,
  coreutils,
  curl,
  jq,
}:

stdenv.mkDerivation {
  pname = "audiobookshelf-bootstrap";
  version = "1.0";

  src = ./bootstrap-audiobookshelf.sh;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    install -Dm755 $src $out/bin/audiobookshelf-bootstrap
    wrapProgram $out/bin/audiobookshelf-bootstrap \
      --prefix PATH : "${
        lib.makeBinPath [
          coreutils
          curl
          jq
        ]
      }"
  '';
}

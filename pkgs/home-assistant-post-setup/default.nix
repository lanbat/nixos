{
  lib,
  stdenv,
  makeWrapper,
  jq,
  coreutils,
  openssl,
}:

stdenv.mkDerivation {
  pname = "home-assistant-post-setup";
  version = "1.0";

  src = ./setup-ha.sh;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    install -Dm755 $src $out/bin/home-assistant-post-setup
    wrapProgram $out/bin/home-assistant-post-setup \
      --prefix PATH : "${
        lib.makeBinPath [
          jq
          coreutils
          openssl
        ]
      }"
  '';
}

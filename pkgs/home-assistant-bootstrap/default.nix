{
  lib,
  stdenv,
  makeWrapper,
  curl,
  jq,
  openssl,
  home-assistant,
}:

stdenv.mkDerivation {
  pname = "home-assistant-bootstrap";
  version = "1.0";

  src = ./bootstrap-ha.sh;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    install -Dm755 $src $out/bin/home-assistant-bootstrap
    wrapProgram $out/bin/home-assistant-bootstrap \
      --prefix PATH : "${lib.makeBinPath [ curl jq openssl home-assistant ]}"
  '';
}

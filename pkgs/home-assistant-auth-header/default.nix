{
  lib,
  fetchFromGitHub,
  buildHomeAssistantComponent,
}:

buildHomeAssistantComponent rec {
  owner = "BeryJu";
  domain = "auth_header";
  version = "1.12";

  src = fetchFromGitHub {
    owner = "BeryJu";
    repo = "hass-auth-header";
    tag = "v${version}";
    hash = "sha256-BPG/G6IM95g9ip2OsPmcAebi2ZvKHUpFzV4oquOFLPM=";
  };

  doCheck = false;
  dontBuild = true;

  meta = {
    description = "Delegate Home Assistant authentication to a reverse proxy header";
    homepage = "https://github.com/BeryJu/hass-auth-header";
    license = lib.licenses.gpl3Only;
  };
}

{
  lib,
  fetchFromGitHub,
  buildHomeAssistantComponent,
  home-assistant,
}:

buildHomeAssistantComponent rec {
  owner = "jekalmin";
  domain = "extended_openai_conversation";
  version = "2.0.2";

  src = fetchFromGitHub {
    owner = "jekalmin";
    repo = "extended_openai_conversation";
    tag = version;
    hash = "sha256-ewtpS/wxOZkCQD1qIip/gIQ3jbyi5wp0b2DypuyISV8=";
  };

  dependencies = [ home-assistant.python.pkgs.openai ];

  # The manifest pins openai~=2.21.0; Home Assistant ships a newer 2.x.
  ignoreVersionRequirement = [ "openai" ];

  doCheck = false;
  dontBuild = true;

  meta = {
    description = "Home Assistant conversation agent for any OpenAI-compatible chat completions API";
    homepage = "https://github.com/jekalmin/extended_openai_conversation";
    license = lib.licenses.mit;
  };
}

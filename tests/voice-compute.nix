# tests/voice-compute.nix
#
# lanbat.deployment.voiceCompute.profile (lib/voice-compute.nix), by pure
# evaluation of the example server under variants of its deployment:
#
#   - "low-spec" (the default) keeps the small speech-to-text model and short
#     LLM replies; an outside API there still needs its key and is kept warm.
#   - "apple-silicon" with a Mac on the LAN that takes no key: no key secret,
#     no llama.cpp, a larger speech-to-text model, longer replies, and the
#     keepalive without an Authorization header.
#   - "apple-silicon" with the LLM on the loopback is rejected.
#
# Its own check, like music-assistant-sources: every variant is a whole system.
{
  lib,
  pkgs,
  inputs,
  self,
  agenix,
  disko,
  deploy-rs,
  nixpkgs,
  nixos-raspberrypi,
}:

let
  inputsWithSelf = inputs // {
    self = self // {
      lanbatPlugins = import ../plugins;
    };
  };

  exampleDeploy = import ../deployments/example/deploy.nix { inputs = inputsWithSelf; };

  lanbatLib = import ../lib {
    self = inputsWithSelf.self;
    inputs = inputsWithSelf;
    profiles = { };
    inherit
      nixpkgs
      nixos-raspberrypi
      agenix
      disko
      deploy-rs
      ;
  };

  # The example server with these deployment settings merged in.
  serverWith =
    deployment:
    (lanbatLib.mkProfile "example" (
      exampleDeploy
      // {
        deployment = exampleDeploy.deployment // deployment;
      }
    )).configurations.example-server.config;

  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);

  lowSpec = serverWith { };
  mac = serverWith {
    voiceCompute.profile = "apple-silicon";
    haLlm = {
      baseUrl = "http://192.0.2.20:8080/v1";
      model = "qwen3-14b";
      apiKey = false;
    };
  };
  macOnLoopback = serverWith {
    voiceCompute.profile = "apple-silicon";
    haLlm = {
      baseUrl = "http://127.0.0.1:8091/v1";
      model = "qwen3-1.7b";
    };
  };

  sttModel = config: config.services.wyoming.faster-whisper.servers.main.model;
  postSetup = config: config.systemd.services.home-assistant-post-setup.script;
  keepalive = config: config.systemd.services.ha-llm-keepalive.script;

  checks = {
    "low-spec is the default" = lowSpec.lanbat.deployment.voiceCompute.profile == "low-spec";
    "low-spec transcribes with base-int8" = sttModel lowSpec == "base-int8";
    "low-spec keeps replies short" = lib.hasInfix ''LLM_MAX_TOKENS="150"'' (postSetup lowSpec);
    "an outside API needs its key" =
      lowSpec.lanbat.secrets ? ha-llm-api-key
      && lib.hasInfix "LLM_API_KEY_FILE" (postSetup lowSpec)
      && lib.hasInfix "Authorization" (keepalive lowSpec);
    "low-spec passes" = failedAssertions lowSpec == [ ];

    "apple-silicon transcribes with small-int8" = sttModel mac == "small-int8";
    "apple-silicon allows longer replies" = lib.hasInfix ''LLM_MAX_TOKENS="300"'' (postSetup mac);
    "a Mac without a key needs no secret" =
      !(mac.lanbat.secrets ? ha-llm-api-key) && !(lib.hasInfix "LLM_API_KEY_FILE" (postSetup mac));
    "the Mac is kept warm without a key" =
      lib.hasInfix "192.0.2.20:8080" (keepalive mac) && !(lib.hasInfix "Authorization:" (keepalive mac));
    "no model runs on the server" = !mac.services.llama-cpp.enable;
    "apple-silicon passes" = failedAssertions mac == [ ];

    "apple-silicon rejects a loopback LLM" = lib.any (lib.hasInfix "voiceCompute.profile") (
      failedAssertions macOnLoopback
    );
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
if failed != [ ] then
  throw "voice-compute: failed: ${lib.concatStringsSep "; " failed}"
else
  pkgs.runCommand "voice-compute" { } ''
    echo ${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.attrNames checks))} > $out
  ''

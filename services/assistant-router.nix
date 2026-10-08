# services/assistant-router.nix
#
# The assistant router: Home Assistant's LLM agent calls it instead of a
# model (lanbat.deployment.haLlm.baseUrl = "http://127.0.0.1:8092/v1",
# model "assistant"). Requests Home Assistant's own intents didn't match
# reach it; it drops noise (fragments, the assistant's own words, radio and
# film speech), lets the local model (services/llama-cpp.nix) act on clear
# device commands, and passes everything else to the cloud through the LLM
# gateway (services/llm-gateway.nix). See pkgs/assistant-router.
#
# Each request is logged, one JSON line, in
# /var/lib/assistant-router/requests.jsonl: what was heard, which tier
# answered, how and how fast.
#
# Always-on: it is in the voice path. Loopback only.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  hostLib = import ../lib/host.nix { inherit lib; };
  enabled = hostLib.haLlmIsRouter (config.lanbat.deployment.haLlm or null);
  cfg = config.lanbat.services.assistant-router.settings;
  port = 8092;
  router = pkgs.callPackage ../pkgs/assistant-router { };
  routerSettings.options.mode = mkOption {
    type = types.enum [
      "local-first"
      "cloud-first"
      "local-only"
    ];
    default = "local-first";
    description = ''
      local-first: the local model acts on clear device commands and hands the
      rest to the cloud. cloud-first: everything Home Assistant's intents
      miss goes to the cloud. local-only: no cloud; requests that need it get
      an honest "I can't do that offline".
    '';
  };
in
{
  config = lib.mkMerge [
    { lanbat.settingsSchema.assistant-router = routerSettings; }
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = config.lanbat.deployment.haLlm.model == "assistant";
          message = "lanbat: with the assistant router, lanbat.deployment.haLlm.model must be \"assistant\".";
        }
      ];
      lanbat.services.assistant-router.port = port;
      systemd.services.assistant-router = {
        description = "Assistant router: noise gate, local triage, cloud escalation";
        wantedBy = [ "multi-user.target" ];
        after = [
          "llama-cpp.service"
          "llm-gateway.service"
        ];
        wants = [ "llama-cpp.service" ];
        serviceConfig = {
          ExecStart = lib.concatStringsSep " " [
            (lib.getExe router)
            "--port ${toString port}"
            "--local-url http://127.0.0.1:${toString config.lanbat.services.llama-cpp.port}/v1/chat/completions"
            "--local-model ${config.lanbat.services.llama-cpp.settings.model}"
            "--cloud-url http://127.0.0.1:${toString config.lanbat.services.llm-gateway.port}/v1/chat/completions"
            "--cloud-model smart"
            "--mode ${cfg.mode}"
            "--log-path /var/lib/assistant-router/requests.jsonl"
          ];
          DynamicUser = true;
          StateDirectory = "assistant-router";
          Restart = "always";
          RestartSec = 2;
          IPAddressDeny = "any";
          IPAddressAllow = "localhost";
        };
      };
    })
  ];
}

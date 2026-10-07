# lib/voice-compute.nix
#
# Where the voice assistant's heavy work runs, and what each place can afford:
# lanbat.deployment.voiceCompute.profile picks one of the profiles below. The
# satellites (Pi 3, Pi 5, the server's own) are the same in both: they capture,
# detect the wake word, duck the music and play replies, and do nothing heavy.
#
# Goals shared by both profiles
# -----------------------------
# - Routine commands ("turn the kitchen light off") never wait for an LLM:
#   Home Assistant's local intents answer them first (prefer_local_intents).
# - Response audio starts within about 1.5 s of the end of speech for a
#   routine command and 2.5 s for an LLM answer, with a warm backend.
# - Everything stays on the home network: audio, transcripts and voiceprints
#   never go to an outside service.
# - Speaker identification (when added) runs beside speech-to-text, never in
#   front of it, and falls back to "unknown" rather than slowing a reply.
#
# low-spec
# --------
# One small x86 box (a 7th/8th-gen i5 office PC with no GPU) runs Home
# Assistant, the voice pipeline and a small LLM next to everything else, and
# Frigate alone takes about two of its cores. Every model must be small and
# every prompt short and cacheable:
# - LLM: llama.cpp on the loopback (services/llama-cpp.nix), qwen3-1.7b, with a
#   fixed prompt whose start the server keeps cached, one tool, short replies.
#   haLlm may also point at an outside OpenAI-compatible API, or be null for
#   Home Assistant's own agent.
# - Speech-to-text: faster-whisper base-int8, the largest model that keeps the
#   transcript under a few hundred milliseconds on this CPU.
# - Speaker identification: one small ONNX embedder (CAM++ class, ~7M
#   parameters) on the CPU.
#
# apple-silicon
# -------------
# An Apple Silicon Mac on the LAN serves the LLM over an OpenAI-compatible API
# (mlx-lm, llama.cpp with Metal, LM Studio or Ollama) and is not managed by this
# flake. The server stops running a model, which frees three to four cores for
# the rest of the voice pipeline:
# - LLM: the Mac, through haLlm (must not be the loopback). Larger models
#   (8B-14B) for conversation, person context and memory tools. The Mac's
#   unified memory and GPU make long prompts cheap, so the prompt may grow.
# - Speech-to-text: faster-whisper small-int8 on the server: noticeably
#   better transcripts across a room or over music, affordable once the LLM
#   has moved.
# - Speaker identification: a stronger embedder for short commands
#   (ERes2NetV2 class) on the server; audio still never leaves it.
# - The Mac may sleep or unload an idle model: Home Assistant keeps it warm
#   (the haLlm keepalive) and, if it is unreachable, local intents still work.
{ lib }:

let
  profiles = {
    low-spec = {
      speechToTextModel = "base-int8";
      llmMaxTokens = 150;
    };
    apple-silicon = {
      speechToTextModel = "small-int8";
      llmMaxTokens = 300;
    };
  };
in
{
  inherit profiles;
  names = lib.attrNames profiles;

  # The profile of a host's configuration. Read with `or` because a host
  # assembled without the settings module, as the pure-eval tests do, has no
  # deployment to ask.
  forConfig = config: profiles.${config.lanbat.deployment.voiceCompute.profile or "low-spec"};
}

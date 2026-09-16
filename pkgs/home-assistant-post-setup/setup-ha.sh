#!/usr/bin/env bash
# Configure Home Assistant integrations that must use config entries (HA 2024.4+).
set -euo pipefail

HASS_CONFIG="${HASS_CONFIG:-/var/lib/hass}"
CONFIG_ENTRIES="${HASS_CONFIG}/.storage/core.config_entries"
AREA_REGISTRY="${HASS_CONFIG}/.storage/core.area_registry"
RESTORE_STATE="${HASS_CONFIG}/.storage/core.restore_state"
STATE_DIR="${HASS_CONFIG}/.lanbat-post-setup"

MQTT_BROKER="${MQTT_BROKER:-127.0.0.1}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USERNAME="${MQTT_USERNAME:-homeassistant}"
MQTT_PASSWORD="${MQTT_PASSWORD:?MQTT_PASSWORD is required}"

FRIGATE_URL="${FRIGATE_URL:-http://127.0.0.1:5000/}"
MUSIC_ASSISTANT_URL="${MUSIC_ASSISTANT_URL:-http://127.0.0.1:8095}"
PI_HOST="${PI_HOST:?PI_HOST is required}"
# This server's own satellite, when it has one.
LOCAL_SATELLITE_PORT="${LOCAL_SATELLITE_PORT:-}"

# The conversation agent: an OpenAI-compatible chat completions API through
# the extended_openai_conversation component. Unset: Home Assistant's own agent.
LLM_BASE_URL="${LLM_BASE_URL:-}"
LLM_MODEL="${LLM_MODEL:-}"
LLM_API_KEY_FILE="${LLM_API_KEY_FILE:-}"
LLM_DOMAIN="extended_openai_conversation"
LLM_TITLE="Voice LLM"
# Home Assistant names the agent's entity after the title.
LLM_ENTITY="conversation.voice_llm"
LLM_MAX_TOKENS="${LLM_MAX_TOKENS:-150}"
LLM_USE_TOOLS="${LLM_USE_TOOLS:-false}"

# Seconds of silence after a command before speech-to-text runs (Home Assistant
# "Finished speaking detection"): aggressive 0.25, default 0.7, relaxed 1.25.
SATELLITE_VAD="${SATELLITE_VAD:-aggressive}"

PIPELINES="${HASS_CONFIG}/.storage/assist_pipeline.pipelines"
PIPELINE_NAME="Voice"
PIPELINE_LANGUAGE="${PIPELINE_LANGUAGE:-en}"
PIPELINE_STT_LANGUAGE="${PIPELINE_STT_LANGUAGE:-en}"
PIPELINE_TTS_LANGUAGE="${PIPELINE_TTS_LANGUAGE:-en_GB}"
PIPELINE_TTS_VOICE="${PIPELINE_TTS_VOICE:-en_GB-alan-medium}"
PIPELINE_WAKE_WORD="${PIPELINE_WAKE_WORD:-okay_nabu}"

# The voice satellites' token (lanbat.voiceRooms): a long-lived access token of
# a "Voice satellites" user. ha-voice-refresh-token.age holds its record (ID,
# signing key, creation time); the satellites hold the token itself.
VOICE_TOKEN_RECORD_FILE="${VOICE_TOKEN_RECORD_FILE:-}"
AUTH_STORE="${HASS_CONFIG}/.storage/auth"
VOICE_USER_NAME="Voice satellites"
# Turns the record's KEY=value lines into an object, inside jq.
VOICE_RECORD_JQ='$record | split("\n") | map(select(test("^[A-Z_]+=")) | capture("^(?<key>[A-Z_]+)=(?<value>.*)$")) | from_entries'

log() {
  echo "home-assistant-post-setup: $*"
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%S.000000+00:00
}

new_entry_id() {
  openssl rand -hex 13 | tr '[:lower:]' '[:upper:]'
}

state_done() {
  [[ -f "${STATE_DIR}/$1" ]]
}

mark_done() {
  install -o hass -g hass -m 0600 /dev/null "${STATE_DIR}/$1"
}

has_entry() {
  local domain="$1"
  jq -e --arg domain "$domain" '.data.entries[] | select(.domain == $domain)' "$CONFIG_ENTRIES" >/dev/null
}

add_entry() {
  local domain="$1"
  local title="$2"
  local data_json="$3"
  local version="${4:-1}"
  local subentries_json="${5:-[]}"
  local now entry_id tmp
  now="$(now_utc)"
  entry_id="$(new_entry_id)"
  tmp="$(mktemp)"
  # The JSON goes in through file descriptors rather than arguments, so
  # credentials in it stay out of the process list.
  jq --arg now "$now" \
    --arg id "$entry_id" \
    --arg domain "$domain" \
    --arg title "$title" \
    --slurpfile data <(printf '%s' "$data_json") \
    --slurpfile subentries <(printf '%s' "$subentries_json") \
    --argjson version "$version" \
    '.data.entries += [{
      created_at: $now,
      data: $data[0],
      disabled_by: null,
      discovery_keys: {},
      domain: $domain,
      entry_id: $id,
      minor_version: 1,
      modified_at: $now,
      options: {},
      pref_disable_new_entities: false,
      pref_disable_polling: false,
      source: "user",
      subentries: $subentries[0],
      title: $title,
      unique_id: null,
      version: $version
    }]' "$CONFIG_ENTRIES" > "$tmp"
  install -o hass -g hass -m 0600 "$tmp" "$CONFIG_ENTRIES"
  rm "$tmp"
}

ensure_mqtt() {
  if state_done mqtt || has_entry mqtt; then
    mark_done mqtt
    return 0
  fi
  log "adding mqtt broker ${MQTT_BROKER}:${MQTT_PORT}"
  add_entry mqtt "$MQTT_BROKER" "$(jq -n \
    --arg broker "$MQTT_BROKER" \
    --argjson port "$MQTT_PORT" \
    --arg username "$MQTT_USERNAME" \
    --arg password "$MQTT_PASSWORD" \
    '{
      broker: $broker,
      port: $port,
      protocol: "3.1.1",
      username: $username,
      password: $password,
      transport: "tcp",
      birth_message: {topic: "homeassistant/status", payload: "online", qos: 0, retain: false},
      will_message: {topic: "homeassistant/status", payload: "offline", qos: 0, retain: false},
      discovery: true,
      discovery_prefix: "homeassistant"
    }')"
  mark_done mqtt
}

ensure_frigate() {
  if state_done frigate || has_entry frigate; then
    mark_done frigate
    return 0
  fi
  log "adding frigate integration (${FRIGATE_URL})"
  add_entry frigate "Frigate" "$(jq -n --arg url "$FRIGATE_URL" '{url: $url}')" 2
  mark_done frigate
}

ensure_music_assistant() {
  if state_done music_assistant; then
    return 0
  fi
  if has_entry music_assistant; then
    if jq -e '.data.entries[] | select(.domain == "music_assistant" and .data.token != null)' \
      "$CONFIG_ENTRIES" >/dev/null; then
      mark_done music_assistant
      return 0
    fi
    log "music assistant entry exists but has no token; waiting for music-assistant-setup"
    return 0
  fi
  log "music assistant integration will be created by music-assistant-setup"
  mark_done music_assistant
}

ensure_wyoming() {
  local name="$1"
  local host="$2"
  local port="$3"
  local state_key="wyoming-${name}"
  if state_done "$state_key"; then
    return 0
  fi
  if jq -e --arg title "$name" '.data.entries[] | select(.domain == "wyoming" and .title == $title)' "$CONFIG_ENTRIES" >/dev/null; then
    mark_done "$state_key"
    return 0
  fi
  log "adding wyoming service ${name} (${host}:${port})"
  add_entry wyoming "$name" "$(jq -n --arg host "$host" --argjson port "$port" '{host: $host, port: $port}')"
  mark_done "$state_key"
}

llm_enabled() {
  [[ -n "$LLM_BASE_URL" && -n "$LLM_MODEL" && -s "$LLM_API_KEY_FILE" ]]
}

# The agent's replies are spoken: short, plain, and acting on requests without
# asking for confirmation first.
llm_prompt() {
  cat <<'PROMPT'
You are the voice assistant of this home, running in Home Assistant. Your answers are spoken aloud: reply in one or two short, plain sentences, without lists, markdown or emoji.

Current time: {{ now() }}

Devices you can see and control:
```csv
entity_id,name,state,aliases
{% for entity in exposed_entities -%}
{{ entity.entity_id }},{{ entity.name }},{{ entity.state }},{{ entity.aliases | join('/') }}
{% endfor -%}
```

Answer questions about the home from the device states above. When asked to change something, call execute_services straight away, without asking for confirmation, then say briefly what you did. If a request is ambiguous, ask one short question.
PROMPT
}

llm_conversation_json() {
  jq -n --arg id "$(new_entry_id)" --arg title "$LLM_TITLE" \
    --arg model "$LLM_MODEL" --arg prompt "$(llm_prompt)" \
    --argjson max_tokens "$LLM_MAX_TOKENS" --argjson use_tools "$LLM_USE_TOOLS" '[{
      subentry_id: $id,
      subentry_type: "conversation",
      title: $title,
      unique_id: null,
      data: {
        prompt: $prompt,
        chat_model: $model,
        max_tokens: $max_tokens,
        top_p: 1,
        temperature: 0.5,
        max_function_calls_per_conversation: 1,
        attach_username: false,
        use_tools: $use_tools,
        context_threshold: 13000,
        context_truncate_strategy: "clear"
      }
    }]'
}

# True when the agent's entry is missing, or its key, URL or model is out of date.
llm_needed() {
  llm_enabled || return 1
  jq -e --rawfile key "$LLM_API_KEY_FILE" --arg url "$LLM_BASE_URL" --arg model "$LLM_MODEL" \
    --arg domain "$LLM_DOMAIN" --arg title "$LLM_TITLE" \
    --argjson max_tokens "$LLM_MAX_TOKENS" --argjson use_tools "$LLM_USE_TOOLS" \
    --arg prompt "$(llm_prompt)" '
    [.data.entries[] | select(.domain == $domain and .title == $title)] as $entries
    | ($entries | length) == 1
      and $entries[0].data.api_key == ($key | rtrimstr("\n"))
      and $entries[0].data.base_url == $url
      and any($entries[0].subentries[];
          .subentry_type == "conversation"
          and .data.chat_model == $model
          and .data.max_tokens == $max_tokens
          and .data.use_tools == $use_tools
          and .data.prompt == $prompt)
  ' "$CONFIG_ENTRIES" >/dev/null && return 1
  return 0
}

ensure_llm() {
  llm_needed || return 0
  local tmp
  if jq -e --arg domain "$LLM_DOMAIN" --arg title "$LLM_TITLE" \
    '.data.entries[] | select(.domain == $domain and .title == $title)' "$CONFIG_ENTRIES" >/dev/null; then
    log "updating the conversation agent (${LLM_BASE_URL}, ${LLM_MODEL})"
    tmp="$(mktemp)"
    jq --rawfile key "$LLM_API_KEY_FILE" --arg url "$LLM_BASE_URL" --arg model "$LLM_MODEL" \
      --arg domain "$LLM_DOMAIN" --arg title "$LLM_TITLE" --arg now "$(now_utc)" \
      --arg prompt "$(llm_prompt)" --argjson max_tokens "$LLM_MAX_TOKENS" \
      --argjson use_tools "$LLM_USE_TOOLS" '
      .data.entries |= map(
        if .domain == $domain and .title == $title then
          .data.api_key = ($key | rtrimstr("\n"))
          | .data.base_url = $url
          | .modified_at = $now
          | .subentries |= map(
              if .subentry_type == "conversation" then
                .data.chat_model = $model
                | .data.prompt = $prompt
                | .data.max_tokens = $max_tokens
                | .data.use_tools = $use_tools
              else . end)
        else . end)
    ' "$CONFIG_ENTRIES" > "$tmp"
    install -o hass -g hass -m 0600 "$tmp" "$CONFIG_ENTRIES"
    rm "$tmp"
    return 0
  fi
  log "adding the conversation agent (${LLM_BASE_URL}, ${LLM_MODEL})"
  # skip_authentication: otherwise the component lists the API's models while
  # Home Assistant starts, which waits on an endpoint that scales to zero.
  add_entry "$LLM_DOMAIN" "$LLM_TITLE" "$(jq -n --rawfile key "$LLM_API_KEY_FILE" \
    --arg url "$LLM_BASE_URL" --arg title "$LLM_TITLE" '{
      name: $title,
      api_key: ($key | rtrimstr("\n")),
      base_url: $url,
      skip_authentication: true,
      api_provider: "openai"
    }')" 2 "$(llm_conversation_json)"
}

pipeline_json() {
  local conversation="conversation.home_assistant"
  if llm_enabled; then conversation="$LLM_ENTITY"; fi
  jq -n --arg name "$PIPELINE_NAME" --arg conversation "$conversation" \
    --arg language "$PIPELINE_LANGUAGE" --arg stt_language "$PIPELINE_STT_LANGUAGE" \
    --arg tts_language "$PIPELINE_TTS_LANGUAGE" --arg tts_voice "$PIPELINE_TTS_VOICE" \
    --arg wake_word "$PIPELINE_WAKE_WORD" '{
      name: $name,
      language: $language,
      conversation_engine: $conversation,
      conversation_language: $language,
      stt_engine: "stt.faster_whisper",
      stt_language: $stt_language,
      tts_engine: "tts.piper",
      tts_language: $tts_language,
      tts_voice: $tts_voice,
      wake_word_entity: "wake_word.openwakeword",
      wake_word_id: $wake_word,
      prefer_local_intents: true
    }'
}

# The pipeline is written again only when this definition changes, so edits
# made to it in Home Assistant last until then.
pipeline_state_key() {
  echo "pipeline-$(pipeline_json | sha256sum | cut -c1-16)"
}

ensure_pipeline() {
  local key id tmp
  key="$(pipeline_state_key)"
  if state_done "$key"; then return 0; fi
  if [[ ! -f "$PIPELINES" ]]; then
    jq -n '{version: 1, minor_version: 2, key: "assist_pipeline.pipelines", data: {items: [], preferred_item: null}}' > "$PIPELINES"
  fi
  id="$(jq -r --arg name "$PIPELINE_NAME" 'first(.data.items[] | select(.name == $name) | .id) // empty' "$PIPELINES")"
  [[ -n "$id" ]] || id="$(openssl rand -hex 13)"
  log "setting the preferred assist pipeline ${PIPELINE_NAME}"
  tmp="$(mktemp)"
  jq --arg id "$id" --slurpfile pipeline <(pipeline_json) '
    .data.items = [.data.items[] | select(.id != $id)] + [$pipeline[0] + {id: $id}]
    | .data.preferred_item = $id
  ' "$PIPELINES" > "$tmp"
  install -o hass -g hass -m 0600 "$tmp" "$PIPELINES"
  rm "$tmp"
  mark_done "$key"
}

satellite_vad_state_key() {
  echo "satellite-vad-${SATELLITE_VAD}"
}

# Home Assistant defaults Wyoming satellites to relaxed VAD, which waits 1.25 s
# of silence after each command before STT — noticeably slow in a living room.
ensure_satellite_vad() {
  local key tmp count
  key="$(satellite_vad_state_key)"
  if state_done "$key"; then return 0; fi
  [[ -f "$RESTORE_STATE" ]] || return 0
  count="$(jq -r --arg vad "$SATELLITE_VAD" '
    [.data[]
      | select(.state.entity_id | test("_finished_speaking_detection$"))
      | select(.state.state != $vad)] | length
  ' "$RESTORE_STATE")"
  if (( count == 0 )); then
    mark_done "$key"
    return 0
  fi
  log "setting satellite finished speaking detection to ${SATELLITE_VAD}"
  tmp="$(mktemp)"
  jq --arg vad "$SATELLITE_VAD" '
    .data = [.data[]
      | if (.state.entity_id | test("_finished_speaking_detection$")) then
          .state.state = $vad
        else . end]
  ' "$RESTORE_STATE" > "$tmp"
  install -o hass -g hass -m 0600 "$tmp" "$RESTORE_STATE"
  rm "$tmp"
  mark_done "$key"
}

# True when the token's record is missing from Home Assistant or out of date.
# The record goes to jq as a file, so its signing key stays out of the process
# list.
voice_token_needed() {
  [[ -n "$VOICE_TOKEN_RECORD_FILE" && -s "$VOICE_TOKEN_RECORD_FILE" && -f "$AUTH_STORE" ]] || return 1
  jq -e --rawfile record "$VOICE_TOKEN_RECORD_FILE" "
    ($VOICE_RECORD_JQ) as \$r
    | [.data.refresh_tokens[] | select(.id == \$r.VOICE_TOKEN_ID and .jwt_key == \$r.VOICE_TOKEN_JWT_KEY)] as \$tokens
    | (\$tokens | length) == 1
      and ([.data.users[] | select(.id == \$tokens[0].user_id and .is_active)] | length) == 1
  " "$AUTH_STORE" >/dev/null && return 1
  return 0
}

# Adds the "Voice satellites" user (a regular, non-admin user without a login)
# and its long-lived token, replacing an earlier token of that user.
ensure_voice_token() {
  voice_token_needed || return 0
  log "adding the voice satellites' user and token"
  local tmp refresh
  tmp="$(mktemp)"
  refresh="$(mktemp)"
  openssl rand -hex 64 | tr -d '\n' > "$refresh"
  jq --rawfile record "$VOICE_TOKEN_RECORD_FILE" --rawfile refresh "$refresh" \
    --arg name "$VOICE_USER_NAME" --arg new_user_id "$(openssl rand -hex 16)" "
    ($VOICE_RECORD_JQ) as \$r
    | (first(.data.users[] | select(.name == \$name and (.is_owner | not))) // null) as \$existing
    | (if \$existing == null then \$new_user_id else \$existing.id end) as \$user_id
    | .data.users = (if \$existing == null then .data.users + [{
        id: \$user_id,
        group_ids: [\"system-users\"],
        is_owner: false,
        is_active: true,
        name: \$name,
        system_generated: false,
        local_only: false
      }] else .data.users end)
    | .data.refresh_tokens = [.data.refresh_tokens[]
        | select(.id != \$r.VOICE_TOKEN_ID and .client_name != \$name)] + [{
        id: \$r.VOICE_TOKEN_ID,
        user_id: \$user_id,
        client_id: null,
        client_name: \$name,
        client_icon: null,
        token_type: \"long_lived_access_token\",
        created_at: (\$r.VOICE_TOKEN_CREATED | tonumber | todate | sub(\"Z$\"; \"+00:00\")),
        access_token_expiration: 315360000.0,
        token: \$refresh,
        jwt_key: \$r.VOICE_TOKEN_JWT_KEY,
        last_used_at: null,
        last_used_ip: null,
        expire_at: null,
        credential_id: null,
        version: null
      }]
  " "$AUTH_STORE" > "$tmp"
  install -o hass -g hass -m 0600 "$tmp" "$AUTH_STORE"
  rm "$tmp" "$refresh"
}

area_id() {
  openssl rand -hex 16
}

ensure_areas() {
  if state_done areas || [[ ! -f "$AREA_REGISTRY" ]]; then
    [[ -f "$AREA_REGISTRY" ]] && mark_done areas
    return 0
  fi
  log "adding default areas"
  local tmp now new_areas name id
  now="$(now_utc)"
  new_areas='[]'
  for name in Kitchen "Living Room" Bedroom Bathroom Hall Office Garden; do
    id="$(area_id)"
    new_areas="$(jq --arg now "$now" --arg name "$name" --arg id "$id" \
      '. + [{
        aliases: [],
        floor_id: null,
        icon: null,
        id: $id,
        labels: [],
        name: $name,
        picture: null,
        humidity_entity_id: null,
        temperature_entity_id: null,
        created_at: $now,
        modified_at: $now
      }]' <<<"$new_areas")"
  done
  tmp="$(mktemp)"
  jq --argjson new_areas "$new_areas" '
    .data.areas = ($new_areas + (.data.areas // []) | unique_by(.name))
  ' "$AREA_REGISTRY" > "$tmp"
  install -o hass -g hass -m 0600 "$tmp" "$AREA_REGISTRY"
  rm "$tmp"
  mark_done areas
}

wyoming_needed() {
  local name="$1"
  state_done "wyoming-${name}" && return 1
  jq -e --arg title "$name" '.data.entries[] | select(.domain == "wyoming" and .title == $title)' "$CONFIG_ENTRIES" >/dev/null && return 1
  return 0
}

needs_work=false
[[ -f "$CONFIG_ENTRIES" ]] || { log "waiting for Home Assistant storage"; exit 0; }

mkdir -p "$STATE_DIR"
chown hass:hass "$STATE_DIR"
chmod 0700 "$STATE_DIR"

if ! state_done mqtt && ! has_entry mqtt; then needs_work=true; fi
if ! state_done frigate && ! has_entry frigate; then needs_work=true; fi
if ! state_done music_assistant && ! has_entry music_assistant; then needs_work=true; fi
if ! state_done areas && [[ -f "$AREA_REGISTRY" ]]; then needs_work=true; fi
for svc in openwakeword faster-whisper piper satellite; do
  wyoming_needed "$svc" && needs_work=true
done
if [[ -n "$LOCAL_SATELLITE_PORT" ]] && wyoming_needed server-satellite; then needs_work=true; fi
if llm_needed; then needs_work=true; fi
if ! state_done "$(pipeline_state_key)"; then needs_work=true; fi
if ! state_done "$(satellite_vad_state_key)"; then needs_work=true; fi
if voice_token_needed; then needs_work=true; fi

if [[ "$needs_work" != true ]]; then
  log "post-setup already complete"
  exit 0
fi

log "applying home assistant post-setup changes"
systemctl stop home-assistant.service

ensure_mqtt
ensure_frigate
ensure_music_assistant
ensure_wyoming "openwakeword" "127.0.0.1" 10300
ensure_wyoming "faster-whisper" "127.0.0.1" 10301
ensure_wyoming "piper" "127.0.0.1" 10302
ensure_wyoming "satellite" "$PI_HOST" 10700
if [[ -n "$LOCAL_SATELLITE_PORT" ]]; then
  ensure_wyoming "server-satellite" "127.0.0.1" "$LOCAL_SATELLITE_PORT"
fi
ensure_llm
ensure_pipeline
ensure_satellite_vad
ensure_voice_token
ensure_areas

systemctl start home-assistant.service
log "post-setup complete"

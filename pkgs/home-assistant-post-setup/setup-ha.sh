#!/usr/bin/env bash
# Configure Home Assistant integrations that must use config entries (HA 2024.4+).
set -euo pipefail

HASS_CONFIG="${HASS_CONFIG:-/var/lib/hass}"
CONFIG_ENTRIES="${HASS_CONFIG}/.storage/core.config_entries"
AREA_REGISTRY="${HASS_CONFIG}/.storage/core.area_registry"
STATE_DIR="${HASS_CONFIG}/.lanbat-post-setup"

MQTT_BROKER="${MQTT_BROKER:-127.0.0.1}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USERNAME="${MQTT_USERNAME:-homeassistant}"
MQTT_PASSWORD="${MQTT_PASSWORD:?MQTT_PASSWORD is required}"

FRIGATE_URL="${FRIGATE_URL:-http://127.0.0.1:5000/}"
MUSIC_ASSISTANT_URL="${MUSIC_ASSISTANT_URL:-http://127.0.0.1:8095}"
PI_HOST="${PI_HOST:?PI_HOST is required}"

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
  local now entry_id tmp
  now="$(now_utc)"
  entry_id="$(new_entry_id)"
  tmp="$(mktemp)"
  jq --arg now "$now" \
    --arg id "$entry_id" \
    --arg domain "$domain" \
    --arg title "$title" \
    --argjson data "$data_json" \
    --argjson version "$version" \
    '.data.entries += [{
      created_at: $now,
      data: $data,
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
      subentries: [],
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
ensure_areas

systemctl start home-assistant.service
log "post-setup complete"

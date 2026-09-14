#!/usr/bin/env bash
# Wait for Pi storage before Kodi starts scanning libraries.
set -euo pipefail

KODI_HOME="${KODI_HOME:?KODI_HOME must be set}"
USERDATA="${KODI_HOME}/.kodi/userdata"
STORAGE_STAMP="${STORAGE_STAMP:-${KODI_HOME}/.lanbat-kodi-storage-ready}"

log() {
  echo "kodi-bootstrap: $*"
}

wait_for_mount() {
  local path="$1"
  local attempt
  for attempt in $(seq 1 60); do
    if mountpoint -q "$path"; then
      return 0
    fi
    sleep 5
  done
  log "${path} is not mounted"
  return 1
}

if [[ -f "$STORAGE_STAMP" ]]; then
  exit 0
fi

wait_for_mount /mnt/storage-a
wait_for_mount /mnt/storage-b

if [[ ! -d "$USERDATA" ]]; then
  log "Kodi userdata directory is missing"
  exit 1
fi

if [[ -d /mnt/storage-b/media/adult ]] && ! test -r /mnt/storage-b/media/adult; then
  log "media user cannot read /mnt/storage-b/media/adult (needs private group)"
  exit 1
fi

install -d -m 0755 -o media -g media "$(dirname "$STORAGE_STAMP")"
touch "$STORAGE_STAMP"
chown media:media "$STORAGE_STAMP"

log "ready"

#!/usr/bin/env bash
# Wait for Pi storage, install repository addons, and enable bundled Kodi addons.
set -euo pipefail

KODI_HOME="${KODI_HOME:-/var/lib/kodi}"
USERDATA="${KODI_HOME}/.kodi/userdata"
ADDONS_DIR="${KODI_HOME}/.kodi/addons"
STORAGE_STAMP="${STORAGE_STAMP:-/var/lib/kodi/.lanbat-kodi-storage-ready}"
ADDON_STAMP="${ADDON_STAMP:-/var/lib/kodi/.lanbat-kodi-addons-enabled}"

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

install_repo_zip() {
  local namespace="$1"
  local url="$2"
  if [[ -d "${ADDONS_DIR}/${namespace}" ]]; then
    return 0
  fi
  local tmp work
  tmp=$(mktemp -d)
  log "installing ${namespace}"
  curl -fsSL "$url" -o "$tmp/repo.zip"
  unzip -q "$tmp/repo.zip" -d "$tmp"
  work=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
  install -d -m 0755 -o media -g media "$ADDONS_DIR"
  cp -a "$work" "${ADDONS_DIR}/${namespace}"
  chown -R media:media "${ADDONS_DIR}/${namespace}"
  rm -rf "$tmp"
}

ensure_favourites() {
  local fav="${USERDATA}/favourites.xml"
  [[ -f "$fav" ]] || return 0
  if grep -q 'PlayStation Remote Play' "$fav"; then
    return 0
  fi
  sed -i 's|</favourites>|  <favourite name="PlayStation Remote Play">System.Exec(&quot;/run/current-system/sw/bin/tv-switch chiaki&quot;)</favourite>\n</favourites>|' \
    "$fav"
  chown media:media "$fav"
  log "added PlayStation Remote Play favourite"
}

install_repositories() {
  install_repo_zip repository.jurialmunkey \
    "https://github.com/jurialmunkey/repository.jurialmunkey/archive/ce3217ab8e196b9abf01633ec770451d8da2a547.zip"
  install_repo_zip repository.marcelveldt \
    "https://github.com/marcelveldt/repository.marcelveldt/archive/3e9323ae915170f11025967f7e18cd3f3456f625.zip"
}

enable_addons() {
  local db
  shopt -s nullglob
  local dbs=("${USERDATA}/Database"/Addons*.db)
  shopt -u nullglob
  if ((${#dbs[@]} == 0)); then
    return 1
  fi
  db="${dbs[0]}"

  local addons=(
    plugin.video.youtube
    inputstream.adaptive
    inputstream.ffmpegdirect
    script.module.inputstreamhelper
    service.upnext
    vfs.rar
    peripheral.joystick
    script.module.jurialmunkey
    repository.jurialmunkey
    repository.marcelveldt
  )

  local quoted
  quoted=$(printf "'%s'," "${addons[@]}")
  quoted=${quoted%,}

  sqlite3 "$db" "UPDATE installed SET enabled=1 WHERE addonID IN (${quoted});"
  log "enabled bundled addons in ${db}"
  return 0
}

if [[ -f "$STORAGE_STAMP" && -f "$ADDON_STAMP" ]]; then
  install_repositories
  ensure_favourites
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

install_repositories
ensure_favourites

if enable_addons; then
  touch "$ADDON_STAMP"
  chown media:media "$ADDON_STAMP"
else
  log "waiting for Kodi to create its addon database"
fi

log "ready"

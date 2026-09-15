#!/usr/bin/env bash
# Wait for Pi storage, then seed Kodi library sources with content types.
set -euo pipefail

KODI_HOME="${KODI_HOME:?KODI_HOME must be set}"
USERDATA="${KODI_HOME}/.kodi/userdata"
STORAGE_STAMP="${STORAGE_STAMP:-${KODI_HOME}/.lanbat-kodi-storage-ready}"
LIBRARY_STAMP="${LIBRARY_STAMP:-${KODI_HOME}/.lanbat-kodi-library-configured}"

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

find_db() {
  local pattern="$1"
  shopt -s nullglob
  local matches=("${USERDATA}/Database"/${pattern})
  shopt -u nullglob
  if ((${#matches[@]} == 0)); then
    return 1
  fi
  printf '%s\n' "${matches[0]}"
}

ensure_storage() {
  if [[ -f "$STORAGE_STAMP" ]]; then
    return 0
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
  log "storage ready"
}

ensure_scan_on_startup() {
  local settings="${USERDATA}/advancedsettings.xml"
  [[ -f "$settings" ]] || return 0

  if grep -q '<scanonstartup>true</scanonstartup>' "$settings"; then
    return 0
  fi

  sed -i \
    -e 's|<scanonstartup>false</scanonstartup>|<scanonstartup>true</scanonstartup>|g' \
    "$settings"
  chown media:media "$settings"
  log "enabled library scan on startup"
}

upsert_video_source() {
  local db="$1"
  local path="$2"
  local content="$3"
  local scraper="$4"
  local recursive="$5"
  local folder_names="$6"

  sqlite3 "$db" <<SQL
INSERT INTO path (
  strPath, strContent, strScraper, scanRecursive, useFolderNames, dateAdded
) SELECT
  '${path}', '${content}', '${scraper}', ${recursive}, ${folder_names}, datetime('now')
WHERE NOT EXISTS (SELECT 1 FROM path WHERE strPath = '${path}');

UPDATE path SET
  strContent = '${content}',
  strScraper = '${scraper}',
  scanRecursive = ${recursive},
  useFolderNames = ${folder_names},
  noUpdate = 0,
  exclude = 0
WHERE strPath = '${path}';
SQL
}

configure_video_library() {
  local db
  db="$(find_db 'MyVideos*.db')" || {
    log "waiting for Kodi to create its video library database"
    return 1
  }

  # name|path|content|scraper|recursive|useFolderNames
  local specs=(
    "movies|/mnt/storage-a/media/movies/|movies|metadata.themoviedb.org.python|1|0"
    "tv|/mnt/storage-a/media/tv/|tvshows|metadata.tvshows.themoviedb.org.python|0|1"
    "music-videos|/mnt/storage-a/media/music-videos/|musicvideos|metadata.local|1|0"
    "documentaries|/mnt/storage-b/media/documentaries/|movies|metadata.themoviedb.org.python|1|0"
    "gym|/mnt/storage-b/media/gym/|movies|metadata.themoviedb.org.python|1|0"
    "games|/mnt/storage-b/media/games/|movies|metadata.themoviedb.org.python|1|0"
    "misc|/mnt/storage-b/media/misc/|movies|metadata.themoviedb.org.python|1|0"
    "adult|/mnt/storage-b/media/adult/|none|metadata.local|1|0"
  )

  local spec name path content scraper recursive folder_names
  for spec in "${specs[@]}"; do
    IFS='|' read -r name path content scraper recursive folder_names <<< "$spec"
    if [[ ! -d "$path" ]]; then
      log "skipping ${name} (${path} not mounted yet)"
      continue
    fi
    upsert_video_source "$db" "$path" "$content" "$scraper" "$recursive" "$folder_names"
    log "configured video source ${name} -> ${path} (${content})"
  done

  local missing
  missing="$(sqlite3 "$db" "SELECT COUNT(*) FROM path WHERE strPath LIKE '/mnt/storage-%' AND (strContent IS NULL OR strContent = '' OR strScraper IS NULL OR strScraper = '');")"
  if [[ "$missing" != "0" ]]; then
    log "${missing} video source(s) still missing content types"
    return 1
  fi

  return 0
}

upsert_music_source() {
  local db="$1"
  local name="$2"
  local path="$3"

  sqlite3 "$db" <<SQL
INSERT INTO source (strName, strMultipath)
SELECT '${name}', '${path}'
WHERE NOT EXISTS (
  SELECT 1 FROM source WHERE strMultipath = '${path}'
);
SQL
}

configure_music_library() {
  local db
  db="$(find_db 'MyMusic*.db')" || {
    log "waiting for Kodi to create its music library database"
    return 1
  }

  local specs=(
    "Music|/mnt/storage-b/media/music/"
    "Audiobooks|/mnt/storage-b/media/audiobooks/"
  )

  local spec name path
  for spec in "${specs[@]}"; do
    IFS='|' read -r name path <<< "$spec"
    if [[ ! -d "$path" ]]; then
      log "skipping ${name} (${path} not mounted yet)"
      continue
    fi
    upsert_music_source "$db" "$name" "$path"
    log "configured music source ${name} -> ${path}"
  done

  return 0
}

library_populated() {
  local video_db music_db movies songs
  video_db="$(find_db 'MyVideos*.db')" || return 1
  music_db="$(find_db 'MyMusic*.db')" || return 1

  movies="$(sqlite3 "$video_db" "SELECT COUNT(*) FROM movie;")"
  songs="$(sqlite3 "$music_db" "SELECT COUNT(*) FROM song;")"
  [[ "$movies" -gt 0 || "$songs" -gt 0 ]]
}

ensure_storage
ensure_scan_on_startup

if [[ -f "$LIBRARY_STAMP" ]] && library_populated; then
  exit 0
fi

if configure_video_library && configure_music_library; then
  install -d -m 0755 -o media -g media "$(dirname "$LIBRARY_STAMP")"
  touch "$LIBRARY_STAMP"
  chown media:media "$LIBRARY_STAMP"
  log "library sources configured; restart Kodi to scan"
else
  log "library setup incomplete (waiting for Kodi databases or media paths)"
  exit 0
fi

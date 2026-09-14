#!/usr/bin/env bash
# Run Kodi; on a normal quit, hand off to EmulationStation.
set -euo pipefail

state=/var/lib/tv-session/current
switching=/var/lib/tv-session/switching
userdata="${HOME}/.kodi/userdata"
addon_stamp=/var/lib/kodi/.lanbat-kodi-addons-enabled

terminating=0
trap 'terminating=1' TERM INT

enable_addons_if_needed() {
  [[ -f "$addon_stamp" ]] && return 0
  shopt -s nullglob
  local dbs=("${userdata}/Database"/Addons*.db)
  shopt -u nullglob
  ((${#dbs[@]} == 0)) && return 0

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

  sqlite3 "${dbs[0]}" "UPDATE installed SET enabled=1 WHERE addonID IN (${quoted});"
  touch "$addon_stamp"
}

enable_addons_if_needed
kodi-standalone
exit_code=$?

enable_addons_if_needed

if [[ "$terminating" == 1 || -f "$switching" ]]; then
  exit 0
fi

if [[ "$exit_code" -eq 0 ]]; then
  echo games >"$state"
  systemctl start --no-block tv-games.service
fi

exit "$exit_code"

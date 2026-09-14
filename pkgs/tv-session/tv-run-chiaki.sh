#!/usr/bin/env bash
# Run chiaki-ng; on exit, hand off to Kodi.
set -euo pipefail

state=/var/lib/tv-session/current
switching=/var/lib/tv-session/switching

terminating=0
trap 'terminating=1' TERM INT

cage -s -- chiaki
exit_code=$?

if [[ "$terminating" == 1 || -f "$switching" ]]; then
  exit 0
fi

echo kodi >"$state"
systemctl start --no-block tv-kodi.service
exit "$exit_code"

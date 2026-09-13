# Start a TV session and remember it for the next boot.
# Usage: tv-switch kodi|games|toggle
state=/var/lib/tv-session/current

case "${1:-toggle}" in
kodi | games)
  next=$1
  ;;
toggle)
  if systemctl is-active --quiet tv-games.service; then next=kodi; else next=games; fi
  ;;
*)
  echo "usage: tv-switch kodi|games|toggle" >&2
  exit 2
  ;;
esac

# Replace the file rather than write into it: root (the controller hotkey)
# and the media user (the sessions) both update it.
tmp=$(mktemp "$state.XXXXXX")
echo "$next" >"$tmp"
chmod 0664 "$tmp"
mv "$tmp" "$state"

# --no-block: starting the other session stops the one this may run in.
systemctl start --no-block "tv-$next.service"

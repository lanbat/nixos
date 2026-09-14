# Start a TV session and remember it for the next boot.
# Usage: tv-switch kodi|games|chiaki|toggle
state=/var/lib/tv-session/current
switching=/var/lib/tv-session/switching

case "${1:-toggle}" in
kodi | games | chiaki)
  next=$1
  ;;
toggle)
  if systemctl is-active --quiet tv-games.service; then next=kodi; else next=games; fi
  ;;
*)
  echo "usage: tv-switch kodi|games|chiaki|toggle" >&2
  exit 2
  ;;
esac

tmp=$(mktemp "$state.XXXXXX")
echo "$next" >"$tmp"
chmod 0664 "$tmp"
mv "$tmp" "$state"

touch "$switching"
systemctl stop tv-kodi.service tv-games.service tv-chiaki.service 2>/dev/null || true
rm -f "$switching"
systemctl start --no-block "tv-$next.service"

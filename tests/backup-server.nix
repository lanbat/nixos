# tests/backup-server.nix
#
# pkgs/scripts/backup-server.sh copies each service's state with copy_state,
# which skips a directory the host does not have instead of failing the whole
# backup: a profile need not run every service, and a service's state can move
# (Frigate's config is now rendered from the profile). Runs the script's own
# copy_state in bash against a scratch tree.
{ pkgs }:

pkgs.runCommand "backup-server-check" { nativeBuildInputs = [ pkgs.rsync ]; } ''
  set -euo pipefail
  # The function as the script defines it, from "copy_state() {" to its closing "}".
  sed -n '/^copy_state() {$/,/^}$/p' ${../pkgs/scripts/backup-server.sh} > copy_state.sh
  grep -q 'copy_state()' copy_state.sh || { echo "FAIL: backup-server.sh defines no copy_state"; exit 1; }
  source ./copy_state.sh

  DEST=$PWD/dest
  mkdir -p src/present "$DEST"
  echo data > src/present/file

  copy_state src/present present > out.txt
  [ "$(cat "$DEST/present/file")" = data ] || { echo "FAIL: a present directory is not copied"; exit 1; }

  copy_state src/absent absent > out.txt
  grep -q 'Skipping src/absent' out.txt || { echo "FAIL: an absent directory is not reported"; exit 1; }
  [ ! -e "$DEST/absent" ] || { echo "FAIL: an absent directory left a copy"; exit 1; }

  # Extra rsync options pass through.
  mkdir -p src/opts/index-x
  echo keep > src/opts/keep
  copy_state src/opts opts --exclude 'index-*' > out.txt
  [ -e "$DEST/opts/keep" ] && [ ! -e "$DEST/opts/index-x" ] || { echo "FAIL: rsync options are not passed through"; exit 1; }

  # No state copy bypasses copy_state.
  if grep -nE '^\s*rsync ' ${../pkgs/scripts/backup-server.sh} | grep -v 'copy_state' | grep -vE '^[0-9]+:\s*rsync -a --delete "\$@"'; then
    echo "FAIL: a state copy calls rsync directly instead of copy_state"; exit 1
  fi
  touch $out
''

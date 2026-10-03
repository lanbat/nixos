#!/usr/bin/env bash
# Move pkgs/jackett to the newest upstream release.
#
#   pkgs/jackett/update.sh           # newest release, if it is newer
#   pkgs/jackett/update.sh 0.24.2800 # a given version
#   pkgs/jackett/update.sh --force   # regenerate hash and deps.json anyway
#
# Rewrites `version` and `hash` in default.nix and regenerates deps.json (the
# NuGet lockfile; this needs network access and takes a few minutes). It does
# not commit. Build the result before committing:
#   nix build --no-link .#checks.x86_64-linux.service-settings
set -euo pipefail

cd "$(dirname "$0")/../.."
dir=pkgs/jackett

current=$(sed -n 's/^  version = "\(.*\)";/\1/p' "$dir/default.nix")
force=
want=
for arg in "$@"; do
  case $arg in
    --force) force=1 ;;
    *) want=$arg ;;
  esac
done

if [ -z "$want" ]; then
  want=$(curl -fsS --max-time 30 https://api.github.com/repos/Jackett/Jackett/releases/latest \
    | jq -r '.tag_name | ltrimstr("v")')
fi
[[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Not a Jackett version: '$want'" >&2
  exit 1
}

if [ "$want" = "$current" ] && [ -z "$force" ]; then
  echo "Already at $current"
  exit 0
fi

echo "Jackett $current -> $want"
raw=$(nix-prefetch-url --unpack --type sha256 \
  "https://github.com/Jackett/Jackett/archive/refs/tags/v$want.tar.gz")
hash=$(nix hash convert --hash-algo sha256 --to sri "$raw")

sed -i \
  -e "s|^  version = \".*\";|  version = \"$want\";|" \
  -e "s|^    hash = \".*\";|    hash = \"$hash\";|" \
  "$dir/default.nix"

# fetch-deps is built from the package as it now is, so it needs the new hash.
script=$(nix build --no-link --print-out-paths --impure --expr "
  let pkgs = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
  in (pkgs.callPackage ./$dir { }).fetch-deps")
"$script" "$dir/deps.json"

echo "Updated to $want. Review the diff, then build and commit."

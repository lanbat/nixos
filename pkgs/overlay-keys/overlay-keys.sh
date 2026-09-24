# overlay-keys — generate the wireguard-mesh keypairs of a profile's hosts.
#
# Usage: nix run .#overlay-keys -- [--profile NAME] [--secrets-dir DIR] [--force] [HOST...]
#
# With no HOST, every host of the profile gets a key. Run it from the flake
# root. DIR (default: secrets) must hold the agenix rules file, secrets.nix,
# with an entry for each overlay-<host>.age, encrypted to that host and to you.

profile=""
secrets_dir="secrets"
force=false
hosts=()

usage() {
  cat >&2 <<'USAGE'
Usage: overlay-keys [--profile NAME] [--secrets-dir DIR] [--force] [HOST...]

With no HOST, every host of the profile gets a key. Run it from the flake root.
DIR (default: secrets) must hold the agenix rules file, secrets.nix, with an
entry for each overlay-<host>.age, encrypted to that host and to you.
USAGE
  exit "${1:-1}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile="${2:?--profile needs a name}"; shift 2 ;;
    --secrets-dir) secrets_dir="${2:?--secrets-dir needs a directory}"; shift 2 ;;
    --force) force=true; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "overlay-keys: unknown option $1" >&2; usage ;;
    *) hosts+=("$1"); shift ;;
  esac
done

if [ ${#hosts[@]} -eq 0 ]; then
  if [ -n "$profile" ]; then arg="\"$profile\""; else arg="null"; fi
  mapfile -t hosts < <(nix eval --raw --apply "f: f $arg" '.#lib.lanbat.deployQuery."host-keys"')
fi

if [ ! -f "$secrets_dir/secrets.nix" ]; then
  echo "overlay-keys: no $secrets_dir/secrets.nix (the agenix rules file)." >&2
  echo "  Copy secrets/secrets.nix.example and add an overlay-<host>.age entry per host." >&2
  exit 1
fi

cd "$secrets_dir"

declare -A public=()
failed=false

for host in "${hosts[@]}"; do
  file="overlay-${host}.age"

  if [ -e "$file" ] && ! $force; then
    if pub=$(agenix -d "$file" 2>/dev/null | wg pubkey 2>/dev/null); then
      public[$host]="$pub"
      echo "overlay-keys: $file exists, kept it." >&2
    else
      echo "overlay-keys: $file exists and could not be decrypted here; kept it." >&2
      echo "  Pass --force to replace it with a new key." >&2
    fi
    continue
  fi

  # agenix -e would open the existing file to edit it; a new key replaces it.
  rm -f "$file"
  private=$(wg genkey)
  if ! printf '%s\n' "$private" | agenix -e "$file" >/dev/null; then
    echo "overlay-keys: could not encrypt $file. Does secrets.nix have a rule for it?" >&2
    failed=true
    unset private
    continue
  fi
  public[$host]=$(printf '%s' "$private" | wg pubkey)
  unset private
  echo "overlay-keys: wrote $secrets_dir/$file" >&2
done

if [ ${#public[@]} -gt 0 ]; then
  echo
  echo "# Public keys for deploy.nix (not secret):"
  for host in "${hosts[@]}"; do
    if [ -n "${public[$host]:-}" ]; then
      echo "hosts.${host}.overlay.publicKey = \"${public[$host]}\";"
    fi
  done
fi

if $failed; then exit 1; fi

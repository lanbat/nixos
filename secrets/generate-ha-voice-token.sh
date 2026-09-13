#!/usr/bin/env bash
# secrets/generate-ha-voice-token.sh
#
# Creates the voice satellites' Home Assistant token (lanbat.voiceRooms):
#
#   ha-voice-token.age          the long-lived access token, for both satellites
#   ha-voice-refresh-token.age  its record: ID, signing key and creation time.
#                               home-assistant-post-setup adds the token, and a
#                               "Voice satellites" user, to Home Assistant.
#
# The token is signed with the record's key, the way Home Assistant signs its
# own long-lived access tokens, so no Home Assistant login is needed. Running
# the script again replaces both; deploy the server and the Pi afterwards.
#
# Run it from the repository root, with secrets/secrets.nix filled in.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp" <<'EOF'
import base64, hashlib, hmac, json, secrets, sys, time, uuid

out = sys.argv[1]


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


token_id = uuid.uuid4().hex
jwt_key = secrets.token_hex(64)
now = int(time.time())
header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
claims = {"iss": token_id, "iat": now, "exp": now + 10 * 365 * 24 * 3600}
payload = b64(json.dumps(claims, separators=(",", ":")).encode())
signature = b64(hmac.new(jwt_key.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest())

with open(f"{out}/token", "w") as f:
    f.write(f"{header}.{payload}.{signature}")
with open(f"{out}/record", "w") as f:
    f.write(f"VOICE_TOKEN_ID={token_id}\nVOICE_TOKEN_JWT_KEY={jwt_key}\nVOICE_TOKEN_CREATED={now}\n")
EOF

encrypt() {
  local name="$1" source="$2" keys
  local -a recipients=()
  keys="$(nix eval --raw --impure --expr \
    "builtins.concatStringsSep \"\n\" (import ./secrets/secrets.nix).\"$name\".publicKeys")"
  # A here-string adds the final newline that nix eval --raw leaves out.
  while IFS= read -r key; do
    [[ -n "$key" ]] && recipients+=(-r "$key")
  done <<<"$keys"
  nix run nixpkgs#age -- "${recipients[@]}" -o "secrets/$name" "$source"
  echo "secrets/$name: encrypted for $((${#recipients[@]} / 2)) keys"
}

encrypt ha-voice-token.age "$tmp/token"
encrypt ha-voice-refresh-token.age "$tmp/record"

{
  pkgs,
}:

# Video channels (YouTube, PeerTube, LBRY/Odysee, Vimeo, ...) as audio podcast
# feeds, for Music Assistant. See bridge.py.
#
# Sites break yt-dlp every few weeks, long before a nixpkgs bump carries the fix,
# so the bridge prefers the newest yt-dlp release that
# media-feed-bridge-update-yt-dlp downloaded into $STATE_DIRECTORY, and falls
# back to the packaged one while there is none. The updater adopts a release only if
# it is an improvement on the one in use: on the configured channels it lists,
# resolves and downloads audio from every channel the current one does, and from
# at least one more.
let
  python = "${pkgs.python3}/bin/python3";

  ytDlp = pkgs.writeShellScript "yt-dlp" ''
    # YT_DLP_FILE is the updater trying a release out.
    latest="''${YT_DLP_FILE:-''${STATE_DIRECTORY:-/nonexistent}/yt-dlp}"
    if [ -s "$latest" ]; then
      exec ${python} "$latest" "$@"
    fi
    exec ${pkgs.yt-dlp}/bin/yt-dlp "$@"
  '';

  bridge = pkgs.writeShellScriptBin "media-feed-bridge" ''
    export YT_DLP=''${YT_DLP:-${ytDlp}}
    # yt-dlp runs a JavaScript runtime for YouTube's signature challenges.
    export PATH=${pkgs.nodejs-slim}/bin:$PATH
    exec ${python} ${./bridge.py} "$@"
  '';

  # media-feed-bridge-update-yt-dlp CONFIG.json
  # Given the bridge's configuration, a release is adopted only if it improves on
  # the yt-dlp in use: on the channels in it (media-feed-bridge --probe: list,
  # resolve, download the start of the audio) it succeeds on all that one does and
  # on at least one more.
  # YT_DLP_RELEASE_URL is for the tests.
  update = pkgs.writeShellApplication {
    name = "media-feed-bridge-update-yt-dlp";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gawk
      pkgs.gnused
      pkgs.python3
    ];
    text = ''
      dir=''${STATE_DIRECTORY:?run with a state directory}
      config=''${1:?usage: media-feed-bridge-update-yt-dlp CONFIG.json}
      # The probes pick the yt-dlp themselves: the candidate, and the one in use.
      unset YT_DLP
      base=''${YT_DLP_RELEASE_URL:-https://github.com/yt-dlp/yt-dlp/releases/latest/download}

      tmp=$(mktemp -p "$dir" .yt-dlp.XXXXXX)
      trap 'rm -f "$tmp"' EXIT

      curl --fail --silent --show-error --location --retry 3 --max-time 180 \
        --output "$tmp" "$base/yt-dlp"
      want=$(curl --fail --silent --show-error --location --retry 3 --max-time 60 \
        "$base/SHA2-256SUMS" | awk '$2 == "yt-dlp" { print $1 }')
      have=$(sha256sum "$tmp" | cut -d' ' -f1)
      if [ -z "$want" ] || [ "$want" != "$have" ]; then
        echo "yt-dlp: the download does not match the release's checksum" >&2
        exit 1
      fi

      # Only a build that starts replaces the one in use...
      version=$(python3 "$tmp" --version)

      # ...and only one that is an improvement on the yt-dlp in use, which is
      # tried again now rather than trusted: on the channels (list them, resolve
      # the audio, download its start) it must play every one the current build
      # plays, and at least one more. A tie is not worth the risk of a change,
      # and neither is a swap of one channel for another.
      played() { sed -n 's/^ok \([^:]*\):.*/\1/p' | sort; }
      echo "trying yt-dlp $version on the channels:"
      candidate=$(YT_DLP_FILE=$tmp ${bridge}/bin/media-feed-bridge --probe "$config")
      printf '%s\n' "$candidate" | sed 's/^/  /'
      echo "the yt-dlp in use, on the same:"
      current=$(env -u YT_DLP_FILE ${bridge}/bin/media-feed-bridge --probe "$config")
      printf '%s\n' "$current" | sed 's/^/  /'
      lost=$(comm -23 <(echo "$current" | played) <(echo "$candidate" | played) | paste -sd' ')
      gained=$(comm -13 <(echo "$current" | played) <(echo "$candidate" | played) | paste -sd' ')
      if [ -n "$lost" ]; then
        echo "yt-dlp $version no longer plays: $lost. Keeping the one in use" >&2
        exit 1
      fi
      if [ -z "$gained" ]; then
        echo "yt-dlp $version plays no channel that the one in use does not. Keeping that" >&2
        exit 1
      fi
      echo "yt-dlp $version newly plays: $gained"

      mv -f "$tmp" "$dir/yt-dlp"
      echo "yt-dlp $version installed"
    '';
  };
in
pkgs.symlinkJoin {
  name = "media-feed-bridge";
  paths = [
    bridge
    update
  ];
  passthru = { inherit ytDlp; };
}

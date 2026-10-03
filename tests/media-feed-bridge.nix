# tests/media-feed-bridge.nix
#
# media-feed-bridge (pkgs/media-feed-bridge), against a stand-in for yt-dlp so
# it runs offline: a channel becomes an audio podcast feed whose enclosures
# point back at the bridge, /audio redirects to what yt-dlp resolves, and it
# serves only the configured sources (no other host, no file: URL, no unknown
# feed), reporting a yt-dlp failure as a 502. The yt-dlp updater is checked
# against a stand-in release server: it installs a build whose checksum matches,
# that starts and that is an improvement on the one in use, meaning that on the
# configured channels (list, resolve, download the audio) it plays every channel
# the one in use plays and at least one more; it keeps the one in use otherwise,
# and the bridge's yt-dlp is the downloaded one once there is one.
#
# Run with: nix build .#checks.x86_64-linux.media-feed-bridge
{ pkgs }:

let
  fakeYtDlp = pkgs.writeShellScript "yt-dlp" ''
    mode=""
    for arg in "$@"; do
      case "$arg" in
        --dump-single-json) mode=list ;;
        --get-url) mode=url ;;
      esac
    done
    url="''${!#}"
    case "$url" in
      *broken*) echo "ERROR: [fake] cannot load $url" >&2; exit 1 ;;
    esac
    if [ "$mode" = list ]; then
      cat <<'JSON'
    {
      "title": "Fake <Channel> &amp; Co",
      "entries": [
        {"_type": "playlist", "entries": [
          {"id": "a1", "title": "First episode", "url": "https://video.example.org/w/a1",
           "duration": 61.5, "timestamp": 1790000000},
          {"id": "b2", "title": "Second\u0001 episode", "url": "https://video.example.org/w/b2",
           "upload_date": "20260101"},
          {"id": "c3", "title": "Elsewhere", "url": "https://elsewhere.example.net/w/c3"}
        ]}
      ]
    }
    JSON
    else
      echo "https://cdn.example.org/audio/$(basename "$url").m4a"
      echo "https://cdn.example.org/video-line-ignored"
    fi
  '';

  bridgePackage = pkgs.callPackage ../pkgs/media-feed-bridge { };

  # A "release" of yt-dlp: a Python program with a checksum list beside it. It
  # lists and resolves like the stand-in above, except one that has regressed,
  # which cannot play anything.
  release =
    {
      version,
      # Channels this release cannot play.
      fails ? [ ],
    }:
    pkgs.runCommand "yt-dlp-release-${version}" { } ''
      mkdir $out
      cat > $out/yt-dlp <<'PY'
      import json, sys
      args = sys.argv[1:]
      MEDIA = "http://127.0.0.1:18102/media/"
      FILES = {
          "fake": "audio.m4a", "hls": "master.m3u8", "extra": "audio.m4a", "more": "audio.m4a",
          "gone": "missing.m4a", "html": "blocked.html", "tiny": "tiny.m4a",
      }
      FAILS = ${builtins.toJSON fails}
      if args == ["--version"]:
          print("fake-yt-dlp ${version}")
      elif "--dump-single-json" in args or "--get-url" in args:
          # The channel's name: .../c/NAME/videos or .../w/NAME
          name = next((p for p in reversed(args[-1].split("/")) if p in FILES or p == "broken"), "")
          if name == "broken" or name in FAILS:
              print("ERROR: cannot play " + args[-1], file=sys.stderr)
              sys.exit(1)
          if "--get-url" in args:
              print(MEDIA + FILES[name])
          else:
              print(json.dumps({"title": "T", "entries": [
                  {"id": name, "url": "https://video.example.org/w/" + name}]}))
      else:
          print("args: " + " ".join(args))
      PY
      (cd $out && sha256sum yt-dlp | sed 's/ \*\?yt-dlp/  yt-dlp/' > SHA2-256SUMS)
    '';
  # What each plays, of the updater test's channels (fake hls extra more):
  release1 = release {
    version = "2026.1.1";
    fails = [
      "hls"
      "extra"
      "more"
    ]; # fake
  };
  release2 = release {
    version = "2026.2.2";
    fails = [
      "extra"
      "more"
    ]; # fake hls
  };
  releaseSame = release {
    version = "2026.2.3";
    fails = [
      "extra"
      "more"
    ]; # fake hls: no improvement
  };
  releaseSwapped = release {
    version = "2026.3.1";
    fails = [ "fake" ]; # hls extra more: more of them, but not fake
  };
  release3 = release {
    version = "2026.4.4"; # all four
  };
  releaseRegressed = release {
    version = "2026.3.3";
    fails = [
      "fake"
      "hls"
      "extra"
      "more"
    ];
  };
  releaseCorrupt = pkgs.runCommand "yt-dlp-release-corrupt" { } ''
    mkdir $out
    cat ${release2}/yt-dlp > $out/yt-dlp
    echo "print('tampered')" >> $out/yt-dlp
    cat ${release2}/SHA2-256SUMS > $out/SHA2-256SUMS
  '';
  releaseBroken = pkgs.runCommand "yt-dlp-release-broken" { } ''
    mkdir $out
    echo "raise SystemExit('does not start')" > $out/yt-dlp
    (cd $out && sha256sum yt-dlp > SHA2-256SUMS)
  '';

  # What the stand-in releases' audio URLs lead to: audio, an HLS playlist down
  # to a segment, a missing file, an error page and a stub.
  media = pkgs.runCommand "media" { } ''
    mkdir $out
    head -c 8192 /dev/zero > $out/audio.m4a
    printf '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nvariant.m3u8\n' > $out/master.m3u8
    printf '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg0.ts\n' > $out/variant.m3u8
    head -c 8192 /dev/zero > $out/seg0.ts
    echo "<html>Sign in to confirm you are not a bot</html>" > $out/blocked.html
    echo stub > $out/tiny.m4a
  '';

  probeConfig = pkgs.writeText "probe.json" (
    builtins.toJSON {
      port = 18101;
      feeds = {
        fake = "https://video.example.org/c/fake/videos";
        hls = "https://video.example.org/c/hls/videos";
        gone = "https://video.example.org/c/gone/videos";
        html = "https://video.example.org/c/html/videos";
        tiny = "https://video.example.org/c/tiny/videos";
        broken = "https://video.example.org/broken";
      };
    }
  );

  updateConfig = pkgs.writeText "update.json" (
    builtins.toJSON {
      port = 18101;
      feeds = {
        fake = "https://video.example.org/c/fake/videos";
        hls = "https://video.example.org/c/hls/videos";
        extra = "https://video.example.org/c/extra/videos";
        more = "https://video.example.org/c/more/videos";
        broken = "https://video.example.org/broken";
      };
    }
  );

  config = pkgs.writeText "bridge.json" (
    builtins.toJSON {
      port = 18101;
      limit = 10;
      feeds = {
        fake = "https://www.video.example.org/c/fake/videos";
        broken = "https://video.example.org/broken";
      };
    }
  );
in
pkgs.runCommand "media-feed-bridge-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.curl
    ];
  }
  ''
    export YT_DLP=${fakeYtDlp}
    python3 ${../pkgs/media-feed-bridge/bridge.py} ${config} &
    bridge=$!
    trap 'kill $bridge' EXIT

    for _ in $(seq 50); do
      curl -fs -o /dev/null http://127.0.0.1:18101/feed/fake.xml && break
      sleep 0.2
    done

    curl -fs http://127.0.0.1:18101/feed/fake.xml -o feed.xml

    python3 - <<'PY'
    import xml.etree.ElementTree as ET
    ns = {"itunes": "http://www.itunes.com/dtds/podcast-1.0.dtd"}
    root = ET.parse("feed.xml").getroot()
    assert root.find("channel/title").text == "Fake <Channel> & Co", root.find("channel/title").text
    items = root.findall("channel/item")
    # The video on another host is left out; the control character is dropped.
    assert [i.find("title").text for i in items] == ["First episode", "Second episode"], items
    first = items[0]
    assert first.find("itunes:duration", ns).text == "61"
    enclosure = first.find("enclosure")
    assert enclosure.get("url") == (
        "http://127.0.0.1:18101/audio?url=https%3A%2F%2Fvideo.example.org%2Fw%2Fa1"
    ), enclosure.get("url")
    assert enclosure.get("type") == "audio/mp4"
    assert first.find("guid").text == "a1"
    PY

    # /audio resolves the video's audio and redirects to it.
    location=$(curl -s -o /dev/null -w '%{redirect_url}' \
      'http://127.0.0.1:18101/audio?url=https%3A%2F%2Fvideo.example.org%2Fw%2Fa1')
    test "$location" = "https://cdn.example.org/audio/a1.m4a" || { echo "got $location"; exit 1; }

    # Only the configured sources' hosts (www. ignored).
    status() { curl -s -o /dev/null -w '%{http_code}' "$1"; }
    test "$(status 'http://127.0.0.1:18101/audio?url=https%3A%2F%2Felsewhere.example.net%2Fw%2Fc3')" = 403
    test "$(status 'http://127.0.0.1:18101/audio?url=file%3A%2F%2F%2Fetc%2Fpasswd')" = 403
    test "$(status 'http://127.0.0.1:18101/audio')" = 403
    test "$(status http://127.0.0.1:18101/feed/unknown.xml)" = 404
    test "$(status http://127.0.0.1:18101/)" = 404

    # A failing yt-dlp is a bad gateway, not a crash.
    test "$(status http://127.0.0.1:18101/feed/broken.xml)" = 502
    test "$(status 'http://127.0.0.1:18101/audio?url=https%3A%2F%2Fvideo.example.org%2Fbroken')" = 502
    test "$(status http://127.0.0.1:18101/feed/fake.xml)" = 200

    # ── the yt-dlp updater ─────────────────────────────────────────────────
    export STATE_DIRECTORY=$PWD/state
    mkdir -p "$STATE_DIRECTORY"
    ytdlp=${bridgePackage.ytDlp}
    update() {
      YT_DLP_RELEASE_URL=http://127.0.0.1:18102/$1 \
        ${bridgePackage}/bin/media-feed-bridge-update-yt-dlp ${updateConfig}
    }

    mkdir -p site
    cp -r ${release1} site/one
    cp -r ${release2} site/two
    cp -r ${releaseCorrupt} site/corrupt
    cp -r ${releaseBroken} site/broken
    cp -r ${releaseRegressed} site/regressed
    cp -r ${releaseSame} site/same
    cp -r ${releaseSwapped} site/swapped
    cp -r ${release3} site/three
    cp -r ${media} site/media
    chmod -R u+w site
    python3 -m http.server 18102 --bind 127.0.0.1 --directory site >/dev/null 2>&1 &
    server=$!
    trap 'kill $bridge $server' EXIT
    for _ in $(seq 50); do
      curl -fs -o /dev/null http://127.0.0.1:18102/one/yt-dlp && break
      sleep 0.2
    done

    # Without a download the packaged yt-dlp is used.
    $ytdlp --version | grep -q . || { echo "packaged yt-dlp does not run"; exit 1; }
    test ! -e "$STATE_DIRECTORY/yt-dlp"

    # A release that plays no channel is no improvement, even on a yt-dlp that
    # plays none.
    if update regressed; then echo "adopted a release that plays nothing"; exit 1; fi
    test ! -e "$STATE_DIRECTORY/yt-dlp"

    update one
    test "$($ytdlp --version)" = "fake-yt-dlp 2026.1.1"
    test "$($ytdlp --flat-playlist url)" = "args: --flat-playlist url"

    update two
    test "$($ytdlp --version)" = "fake-yt-dlp 2026.2.2"

    # The probe on its own, with the release installed: it must download the
    # audio, not just resolve it. A playlist is followed to its segment; a
    # missing file, an error page and a stub are failures.
    probe=$(env -u YT_DLP YT_DLP_FILE=$STATE_DIRECTORY/yt-dlp \
      ${bridgePackage}/bin/media-feed-bridge --probe ${probeConfig})
    echo "$probe"
    echo "$probe" | grep -q '^ok fake: 8192 bytes'
    echo "$probe" | grep -q '^ok hls: 8192 bytes'
    echo "$probe" | grep -q '^fail gone: .*404'
    echo "$probe" | grep -q '^fail html: got a web page or JSON (text/html), not audio'
    echo "$probe" | grep -q '^fail tiny: got only 5 bytes'
    echo "$probe" | grep -q '^fail broken: '
    test "$(echo "$probe" | tail -n 1)" = "passed 2/6"

    # Only an improvement is adopted: every channel the one in use plays, and
    # one more.
    refused() { # release, text its explanation must contain
      explanation=$(update "$1" 2>&1) && { echo "adopted $1"; exit 1; }
      echo "$explanation" | grep -q -- "$2" || { echo "$explanation"; exit 1; }
      test "$($ytdlp --version)" = "fake-yt-dlp 2026.2.2"
    }
    refused same 'plays no channel that the one in use does not'
    refused regressed 'no longer plays: fake hls'
    # Plays more channels (3 against 2) but not fake: a swap, not an improvement.
    refused swapped 'no longer plays: fake'

    update three
    test "$($ytdlp --version)" = "fake-yt-dlp 2026.4.4"

    # A download that does not match its checksum, one that does not start and
    # a missing release each leave the build in use alone, and no temporary file.
    if update corrupt; then echo "accepted a corrupt download"; exit 1; fi
    if update broken; then echo "accepted a build that does not start"; exit 1; fi
    if update nowhere; then echo "accepted a missing release"; exit 1; fi
    test "$($ytdlp --version)" = "fake-yt-dlp 2026.4.4"
    test "$(ls -A "$STATE_DIRECTORY")" = "yt-dlp"

    touch $out
  ''

#!/usr/bin/env python3
"""Serve video channels as audio podcast feeds, for Music Assistant.

Music Assistant has no YouTube, PeerTube, LBRY/Odysee or Vimeo provider, but it
plays any podcast feed. yt-dlp can list and resolve all four sites (and many
more), so this turns each configured channel or playlist into a feed:

  GET /feed/<name>.xml   RSS feed of the channel's newest videos; each item's
                         enclosure points back at /audio
  GET /audio?url=<video> 302 to the video's best audio stream, resolved by
                         yt-dlp at play time (direct URLs expire)

It listens on loopback only and only serves the configured sources: /feed takes
a name from the configuration, and /audio only resolves a URL on the host of a
configured source, so it is not an open proxy for yt-dlp.

Usage: media-feed-bridge CONFIG.json
       media-feed-bridge --probe CONFIG.json
  {"port": 8100, "limit": 50, "feeds": {"name": "https://..."}}
Environment: YT_DLP (the yt-dlp binary, default yt-dlp)

--probe serves nothing: for each feed it lists the source, resolves the audio of
its newest video, as the bridge would, and then downloads the start of that audio
the way a player does (an HLS playlist down to its first segment). It prints "ok
NAME ..." or "fail NAME: reason" per feed and "passed N/M" last. The yt-dlp
updater uses it to try a new yt-dlp release on the real channels before adopting
it.
"""

from __future__ import annotations

import html
import json
import os
import re
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urljoin, urlsplit
from urllib.request import Request, urlopen

YT_DLP = os.environ.get("YT_DLP", "yt-dlp")
# An audio-only stream if there is one. Otherwise the smallest stream with audio
# (the video is thrown away, so do not make Music Assistant download the best of
# it); HLS comes first because a site's plain file is often not seekable.
AUDIO_FORMAT = "bestaudio/worst[acodec!=none][protocol^=m3u8]/worst[acodec!=none]/best"
FEED_TTL = 600  # seconds a generated feed is reused
AUDIO_TTL = 300  # seconds a resolved audio URL is reused
LIST_TIMEOUT = 180
RESOLVE_TIMEOUT = 90
SAMPLE_BYTES = 65536  # how much of the audio a probe fetches
SAMPLE_MIN = 1024  # less than this is an error page or an empty stream
SAMPLE_TIMEOUT = 30
ERROR_TYPES = ("text/html", "application/xhtml+xml", "application/json", "text/xml", "application/xml")
ITUNES = "http://www.itunes.com/dtds/podcast-1.0.dtd"
ET.register_namespace("itunes", ITUNES)

# yt-dlp needs a JavaScript runtime to solve YouTube's signature challenges.
COMMON = [
    "--ignore-config",
    "--no-cache-dir",
    "--no-warnings",
    "--js-runtimes",
    "node",
]
# Characters XML 1.0 cannot carry, which titles and descriptions sometimes have.
INVALID_XML = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]")

# Hosts that serve the same site as a source's host.
HOST_ALIASES = {
    "youtube.com": ["youtu.be", "youtube-nocookie.com"],
    "youtu.be": ["youtube.com"],
}


def log(message: str) -> None:
    print(f"media-feed-bridge: {message}", file=sys.stderr, flush=True)


def normalize_host(host: str | None) -> str:
    host = (host or "").lower()
    for prefix in ("www.", "m."):
        if host.startswith(prefix):
            host = host[len(prefix) :]
    return host


def allowed_hosts(feeds: dict[str, str]) -> set[str]:
    hosts: set[str] = set()
    for source in feeds.values():
        host = normalize_host(urlsplit(source).hostname)
        if host:
            hosts.add(host)
            hosts.update(HOST_ALIASES.get(host, []))
    return hosts


def is_allowed(url: str, hosts: set[str]) -> bool:
    parts = urlsplit(url)
    return parts.scheme in ("http", "https") and normalize_host(parts.hostname) in hosts


def clean(text: object) -> str:
    # Some sites (Vimeo) hand titles over HTML-escaped.
    return INVALID_XML.sub("", html.unescape(str(text or "")))


def list_source(source: str, limit: int) -> dict:
    """The source's metadata and (flat) entries, as yt-dlp reports them."""
    result = subprocess.run(
        [
            YT_DLP,
            *COMMON,
            "--flat-playlist",
            "--playlist-end",
            str(limit),
            "--dump-single-json",
            source,
        ],
        capture_output=True,
        text=True,
        timeout=LIST_TIMEOUT,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip().splitlines()[-1] if result.stderr else "yt-dlp failed")
    return json.loads(result.stdout)


def flatten(info: dict) -> list[dict]:
    """The videos of a source; a channel's tabs are playlists of videos."""
    entries = info.get("entries")
    if entries is None:
        return [info]
    videos: list[dict] = []
    for entry in entries:
        if entry:
            videos.extend(flatten(entry) if entry.get("entries") is not None else [entry])
    return videos


def published(entry: dict, fallback: float) -> float:
    if entry.get("timestamp"):
        return float(entry["timestamp"])
    day = str(entry.get("upload_date") or "")
    if re.fullmatch(r"\d{8}", day):
        return time.mktime(time.strptime(day, "%Y%m%d"))
    return fallback


def build_feed(name: str, source: str, limit: int, base: str, hosts: set[str]) -> bytes:
    info = list_source(source, limit)
    now = time.time()
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = clean(info.get("title") or name)
    ET.SubElement(channel, "link").text = source
    ET.SubElement(channel, "description").text = clean(
        info.get("description") or f"Audio of {source}"
    )
    ET.SubElement(channel, "language").text = "en"
    thumbnail = next(
        (t.get("url") for t in reversed(info.get("thumbnails") or []) if t.get("url")), None
    )
    if thumbnail:
        ET.SubElement(channel, f"{{{ITUNES}}}image", {"href": thumbnail})

    for index, entry in enumerate(flatten(info)):
        url = entry.get("webpage_url") or entry.get("url")
        if not url or not is_allowed(url, hosts):
            continue
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = clean(entry.get("title") or url)
        ET.SubElement(item, "guid", {"isPermaLink": "false"}).text = clean(entry.get("id") or url)
        ET.SubElement(item, "link").text = url
        ET.SubElement(item, "description").text = clean(entry.get("description"))
        # Entries come newest first; a source without dates keeps that order.
        ET.SubElement(item, "pubDate").text = formatdate(
            published(entry, now - index * 3600), usegmt=True
        )
        if entry.get("duration"):
            ET.SubElement(item, f"{{{ITUNES}}}duration").text = str(int(entry["duration"]))
        ET.SubElement(
            item,
            "enclosure",
            {"url": f"{base}/audio?url={quote(url, safe='')}", "type": "audio/mp4", "length": "0"},
        )
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


def resolve_audio(url: str) -> str:
    result = subprocess.run(
        [YT_DLP, *COMMON, "--no-playlist", "-f", AUDIO_FORMAT, "--get-url", url],
        capture_output=True,
        text=True,
        timeout=RESOLVE_TIMEOUT,
        check=False,
    )
    lines = result.stdout.strip().splitlines()
    if result.returncode != 0 or not lines:
        raise RuntimeError(result.stderr.strip().splitlines()[-1] if result.stderr else "yt-dlp failed")
    return lines[0]


def fetch_start(url: str, limit: int) -> tuple[str, bytes]:
    """The content type and first limit bytes of an http(s) URL."""
    if urlsplit(url).scheme not in ("http", "https"):
        raise RuntimeError(f"not an http(s) URL: {url}")
    request = Request(url, headers={"Range": f"bytes=0-{limit - 1}", "User-Agent": "Mozilla/5.0"})
    try:
        with urlopen(request, timeout=SAMPLE_TIMEOUT) as response:  # noqa: S310
            kind = response.headers.get("Content-Type", "").split(";")[0].strip().lower()
            return kind, response.read(limit)
    except OSError as exc:  # HTTP errors, refused connections, timeouts
        raise RuntimeError(f"cannot download from {urlsplit(url).hostname}: {exc}") from exc


def check_download(url: str, depth: int = 0) -> int:
    """Download the start of the audio at url, as a player would, and return how
    many bytes of media came; raise if it is not media. An HLS playlist is
    followed to its first segment."""
    kind, data = fetch_start(url, SAMPLE_BYTES)
    if data.lstrip().startswith(b"#EXTM3U") or "mpegurl" in kind:
        if depth >= 3:
            raise RuntimeError("HLS playlists nest too deeply")
        lines = (line.strip() for line in data.decode("utf-8", "replace").splitlines())
        uris = [line for line in lines if line and not line.startswith("#")]
        if not uris:
            raise RuntimeError("the HLS playlist lists nothing")
        return check_download(urljoin(url, uris[0]), depth + 1)
    # Servers label media carelessly (a .ts segment as text/...), so judge by the
    # content: a refusal or error page is markup or JSON, which no media is.
    if kind in ERROR_TYPES or data.lstrip()[:1] in (b"<", b"{"):
        raise RuntimeError(f"got a web page or JSON ({kind or 'no content type'}), not audio")
    if len(data) < SAMPLE_MIN:
        raise RuntimeError(f"got only {len(data)} bytes of audio")
    return len(data)


class Bridge:
    def __init__(self, config: dict) -> None:
        self.port = int(config["port"])
        self.limit = int(config.get("limit", 50))
        self.feeds: dict[str, str] = config["feeds"]
        self.hosts = allowed_hosts(self.feeds)
        self.base = f"http://127.0.0.1:{self.port}"
        self.lock = threading.Lock()
        self.feed_cache: dict[str, tuple[float, bytes]] = {}
        self.feed_locks = {name: threading.Lock() for name in self.feeds}
        self.audio_cache: dict[str, tuple[float, str]] = {}

    def feed(self, name: str) -> bytes:
        with self.feed_locks[name]:
            cached = self.feed_cache.get(name)
            if cached and time.time() - cached[0] < FEED_TTL:
                return cached[1]
            body = build_feed(name, self.feeds[name], self.limit, self.base, self.hosts)
            self.feed_cache[name] = (time.time(), body)
            return body

    def audio(self, url: str) -> str:
        with self.lock:
            cached = self.audio_cache.get(url)
        if cached and time.time() - cached[0] < AUDIO_TTL:
            return cached[1]
        target = resolve_audio(url)
        with self.lock:
            self.audio_cache[url] = (time.time(), target)
        return target


def make_handler(bridge: Bridge) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "media-feed-bridge"

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002
            log(format % args)

        def reply(self, status: int, body: bytes = b"", headers: dict[str, str] | None = None) -> None:
            self.send_response(status)
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_HEAD(self) -> None:  # noqa: N802
            self.do_GET()

        def do_GET(self) -> None:  # noqa: N802
            parts = urlsplit(self.path)
            try:
                if parts.path.startswith("/feed/") and parts.path.endswith(".xml"):
                    name = unquote(parts.path[len("/feed/") : -len(".xml")])
                    if name not in bridge.feeds:
                        return self.reply(404, b"unknown feed\n")
                    return self.reply(
                        200,
                        bridge.feed(name),
                        {"Content-Type": "application/rss+xml; charset=utf-8"},
                    )
                if parts.path == "/audio":
                    url = parse_qs(parts.query).get("url", [""])[0]
                    if not is_allowed(url, bridge.hosts):
                        return self.reply(403, b"not a configured source\n")
                    return self.reply(302, b"", {"Location": bridge.audio(url)})
                return self.reply(404, b"not found\n")
            except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
                log(f"{parts.path}: {exc}")
                return self.reply(502, b"yt-dlp failed\n")

    return Handler


def probe(config: dict) -> None:
    feeds: dict[str, str] = config["feeds"]
    hosts = allowed_hosts(feeds)
    passed = 0
    for name, source in feeds.items():
        try:
            urls = [
                url
                for entry in flatten(list_source(source, 3))
                if (url := entry.get("webpage_url") or entry.get("url")) and is_allowed(url, hosts)
            ]
            if not urls:
                raise RuntimeError("lists no videos")
            size = check_download(resolve_audio(urls[0]))
        except (RuntimeError, OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
            print(f"fail {name}: {exc}", flush=True)
        else:
            print(f"ok {name}: {size} bytes of audio downloaded", flush=True)
            passed += 1
    print(f"passed {passed}/{len(feeds)}", flush=True)


def main() -> None:
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--probe":
        with open(args[1], encoding="utf-8") as handle:
            return probe(json.load(handle))
    if len(args) != 1:
        sys.exit(__doc__)
    with open(args[0], encoding="utf-8") as handle:
        bridge = Bridge(json.load(handle))
    server = ThreadingHTTPServer(("127.0.0.1", bridge.port), make_handler(bridge))
    log(f"serving {len(bridge.feeds)} feed(s) on 127.0.0.1:{bridge.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()

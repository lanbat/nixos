#!/usr/bin/env python3
"""Kodi's side of a Linux Voice Assistant satellite on the same machine.

Follows LVA's peripheral WebSocket and the local Kodi's JSON-RPC TCP port:

- Pause video while you talk: on the wake word, a video Kodi is playing is
  paused; when the conversation ends (idle) it resumes, but only if this
  paused it and nothing changed it since: a stop, a resume or a "pause the
  TV" command (Home Assistant's Other.tv.hold) wins. It resumes a few
  seconds back (RESUME_REWIND_SECONDS), so the line said over the wake word
  isn't lost. Music Kodi plays is ducked like Snapcast's
  (pkgs/lva-snapcast-duck), not paused.
- Captions: "Listening", what you said and the reply, as Kodi notifications.
- TV power: Home Assistant sends JSONRPC.NotifyAll with the message tv.on or
  tv.off (it arrives here as Other.tv.on / Other.tv.off) and this runs Kodi's
  CECActivateSource or CECStandby through Kodi's EventServer on the loopback.
  Kodi's JSON-RPC has no CEC method, and the EventServer has no
  authentication, so it is not opened to the network.

Kodi's TCP port (9090) speaks JSON-RPC without a password; this connects to
it on the loopback only.
"""
from __future__ import annotations

import asyncio
import itertools
import json
import os
import random
import socket
import struct
import sys

try:
    import websockets
except ImportError:
    print("lva-kodi-companion: websockets package missing", file=sys.stderr)
    sys.exit(1)

LVA_URL = os.environ.get("LVA_PERIPHERAL_URL", "ws://127.0.0.1:6055")
KODI_HOST = os.environ.get("KODI_HOST", "127.0.0.1")
KODI_PORT = int(os.environ.get("KODI_PORT", "9090"))
KODI_ES_PORT = int(os.environ.get("KODI_EVENTSERVER_PORT", "9777"))
CAPTIONS = os.environ.get("CAPTIONS", "1") == "1"
PAUSE_VIDEO = os.environ.get("PAUSE_VIDEO", "1") == "1"
ASSISTANT_NAME = os.environ.get("ASSISTANT_NAME", "Assistant")
CAPTION_MS = int(os.environ.get("CAPTION_MS", "5000"))
REWIND_SECONDS = int(os.environ.get("RESUME_REWIND_SECONDS", "3"))

END_EVENTS = frozenset({"idle", "pipeline_error", "disconnected"})
# Kodi notifications after which a voice pause is no longer ours to undo.
RELEASE_NOTIFICATIONS = frozenset(
    {"Player.OnStop", "Player.OnResume", "Player.OnPlay", "Other.tv.hold", "Other.tv.off"}
)
CEC_ACTIONS = {"Other.tv.on": "CECActivateSource", "Other.tv.off": "CECStandby"}


def log(msg: str) -> None:
    print(f"lva-kodi-companion: {msg}", file=sys.stderr, flush=True)


# ── Kodi EventServer (UDP) ──────────────────────────────────────────────────
# Packet: "XBMC", version 2.0, type, sequence, sequences, payload size,
# client token, 10 reserved bytes, payload.
PT_HELO, PT_BYE, PT_ACTION = 0x01, 0x02, 0x0A
ACTION_EXECBUILTIN = 0x01


def es_packet(ptype: int, payload: bytes, token: int) -> bytes:
    header = b"XBMC" + bytes([2, 0])
    header += struct.pack("!HIIHI", ptype, 1, 1, len(payload), token)
    return header + b"\0" * 10 + payload


def es_builtin(builtin: str) -> None:
    """Run a Kodi builtin through the EventServer: greet, act, leave."""
    token = random.getrandbits(32)
    helo = b"lanbat voice\0" + bytes([0]) + struct.pack("!HII", 0, 0, 0)
    action = bytes([ACTION_EXECBUILTIN]) + builtin.encode() + b"\0"
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        for ptype, payload in ((PT_HELO, helo), (PT_ACTION, action), (PT_BYE, b"")):
            sock.sendto(es_packet(ptype, payload, token), (KODI_HOST, KODI_ES_PORT))


# ── Kodi JSON-RPC over TCP ──────────────────────────────────────────────────
class Kodi:
    """One connection to Kodi's TCP JSON-RPC port. Kodi sends JSON objects
    back to back with no separator: replies to our ids and notifications."""

    def __init__(self, on_notification) -> None:
        self.on_notification = on_notification
        self.writer: asyncio.StreamWriter | None = None
        self.pending: dict[int, asyncio.Future] = {}
        self.ids = itertools.count(1)

    @property
    def connected(self) -> bool:
        return self.writer is not None

    async def call(self, method: str, params: dict | None = None, timeout: float = 3.0):
        if not self.writer:
            return None
        rid = next(self.ids)
        fut = asyncio.get_running_loop().create_future()
        self.pending[rid] = fut
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        try:
            self.writer.write(json.dumps(msg).encode())
            await self.writer.drain()
            reply = await asyncio.wait_for(fut, timeout)
        except (OSError, asyncio.TimeoutError) as exc:
            log(f"{method}: {exc or 'timed out'}")
            return None
        finally:
            self.pending.pop(rid, None)
        if "error" in reply:
            log(f"{method}: {reply['error']}")
            return None
        return reply.get("result")

    async def run(self) -> None:
        delay = 2.0
        decoder = json.JSONDecoder()
        while True:
            try:
                reader, self.writer = await asyncio.open_connection(KODI_HOST, KODI_PORT)
                delay = 2.0
                buf = ""
                while chunk := await reader.read(65536):
                    buf += chunk.decode(errors="replace")
                    while buf:
                        buf = buf.lstrip()
                        try:
                            obj, end = decoder.raw_decode(buf)
                        except json.JSONDecodeError:
                            break  # the rest of the object is still coming
                        buf = buf[end:]
                        self._dispatch(obj)
            except OSError:
                pass  # Kodi not running (the games session, a restart)
            self.writer = None
            for fut in self.pending.values():
                if not fut.done():
                    fut.set_exception(OSError("Kodi connection closed"))
            await asyncio.sleep(delay)
            delay = min(delay * 1.5, 30.0)

    def _dispatch(self, obj) -> None:
        if not isinstance(obj, dict):
            return
        if "id" in obj:
            fut = self.pending.get(obj["id"])
            if fut and not fut.done():
                fut.set_result(obj)
        elif "method" in obj:
            self.on_notification(obj["method"], obj.get("params") or {})


# ── The companion ───────────────────────────────────────────────────────────
class Companion:
    def __init__(self) -> None:
        self.kodi = Kodi(self.on_kodi)
        self.paused_player: int | None = None  # a video this paused for a voice turn
        self.in_turn = False

    def on_kodi(self, method: str, params: dict) -> None:
        if method in RELEASE_NOTIFICATIONS and self.paused_player is not None:
            self.paused_player = None
        builtin = CEC_ACTIONS.get(method)
        if builtin and (params.get("sender") == "lanbat"):
            log(f"{method}: {builtin}")
            try:
                es_builtin(builtin)
            except OSError as exc:
                log(f"EventServer: {exc}")

    async def caption(self, title: str, message: str) -> None:
        if CAPTIONS and message and self.kodi.connected:
            await self.kodi.call(
                "GUI.ShowNotification",
                {"title": title, "message": message[:200], "displaytime": CAPTION_MS},
            )

    async def pause_video(self) -> None:
        if not PAUSE_VIDEO or self.paused_player is not None or not self.kodi.connected:
            return
        players = await self.kodi.call("Player.GetActivePlayers") or []
        for player in players:
            if player.get("type") != "video":
                continue
            pid = player.get("playerid")
            props = await self.kodi.call("Player.GetProperties", {"playerid": pid, "properties": ["speed"]})
            if props and props.get("speed", 0) != 0:
                if await self.kodi.call("Player.PlayPause", {"playerid": pid, "play": False}) is not None:
                    self.paused_player = pid
                return

    async def resume_video(self) -> None:
        pid, self.paused_player = self.paused_player, None
        if pid is None or not self.kodi.connected:
            return
        props = await self.kodi.call("Player.GetProperties", {"playerid": pid, "properties": ["speed"]})
        if props is not None and props.get("speed", 1) == 0:
            if REWIND_SECONDS > 0:
                await self.kodi.call(
                    "Player.Seek", {"playerid": pid, "value": {"seconds": -REWIND_SECONDS}}
                )
            await self.kodi.call("Player.PlayPause", {"playerid": pid, "play": True})

    async def on_lva(self, event: str, data: dict) -> None:
        if event == "wake_word_detected" or (event == "listening" and not self.in_turn):
            self.in_turn = True
            await self.pause_video()
            await self.caption(ASSISTANT_NAME, "Listening…")
        elif event == "stt_text":
            await self.caption("You", data.get("text", ""))
        elif event == "tts_text":
            await self.caption(ASSISTANT_NAME, data.get("text", ""))
        elif event in END_EVENTS:
            self.in_turn = False
            await self.resume_video()

    async def follow_lva(self) -> None:
        delay = 2.0
        while True:
            try:
                async with websockets.connect(LVA_URL) as ws:
                    delay = 2.0
                    async for raw in ws:
                        try:
                            msg = json.loads(raw)
                            event, data = msg.get("event"), msg.get("data") or {}
                        except (json.JSONDecodeError, AttributeError):
                            continue
                        await self.on_lva(event, data)
            except Exception as exc:  # pylint: disable=broad-except
                log(f"LVA: {exc}")
            # LVA gone mid-turn: don't leave the film paused.
            self.in_turn = False
            await self.resume_video()
            await asyncio.sleep(delay)
            delay = min(delay * 1.5, 30.0)


async def amain() -> None:
    companion = Companion()
    await asyncio.gather(companion.kodi.run(), companion.follow_lva())


def main() -> None:
    asyncio.run(amain())


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Fade Snapcast down while Linux Voice Assistant listens or speaks.

Follows LVA's peripheral WebSocket. The music fades down on the wake word and
stays down through listening, thinking, the reply and any follow-up turn (LVA
sends tts_finished and then listening when the conversation continues), and
fades back up on idle. The volume each Snapcast stream had before the fade is
the one it returns to.

Two levels: near silence while the microphone is open (a speech station at a
quarter of its volume is still clear speech to a microphone a metre away, and
ends up in the transcript), and a quieter background while the assistant
thinks and answers.
"""
from __future__ import annotations

import asyncio
import json
import os
import signal
import subprocess
import sys

try:
    import websockets
except ImportError:
    print("lva-snapcast-duck: websockets package missing", file=sys.stderr)
    sys.exit(1)

# The microphone is open.
LISTEN_EVENTS = frozenset({"wake_word_detected", "listening"})
# The assistant is working out or giving its answer.
SPEAK_EVENTS = frozenset({"thinking", "tts_speaking", "timer_ringing"})
# Not tts_finished: a continued conversation follows it with listening, and
# restoring there would pump the music up and down between turns.
RESTORE_EVENTS = frozenset({"idle", "pipeline_error", "disconnected"})

PW_DUMP = os.environ.get("PW_DUMP", "pw-dump")
WPCTL = os.environ.get("WPCTL", "wpctl")
DUCK_VOLUME = float(os.environ.get("DUCK_VOLUME", "0.25"))
DUCK_LISTEN_VOLUME = float(os.environ.get("DUCK_LISTEN_VOLUME", "0.05"))
FADE_DOWN = float(os.environ.get("FADE_DOWN_SECONDS", "0.2"))
FADE_UP = float(os.environ.get("FADE_UP_SECONDS", "0.8"))
# A pipeline that never reports idle (Home Assistant dropped mid-turn without
# the connection closing) must not leave the music down for good.
MAX_DUCK = float(os.environ.get("MAX_DUCK_SECONDS", "120"))
# The volumes to return to, kept on disk while the music is down, so that a
# restarted ducker (a deploy, a crash) puts them back instead of leaving the
# music at a fraction of its volume for good.
STATE_FILE = os.environ.get("STATE_FILE")
STEP = 0.05


def run(*args: str) -> str:
    # wpctl and pw-dump warn on stderr that a system service gets no realtime
    # scheduling; that would fill the journal on every reply.
    return subprocess.run(
        args, check=False, capture_output=True, text=True
    ).stdout


def snapcast_nodes() -> list[int]:
    """PipeWire node ids of snapclient's streams (the process binary is a
    property of its client, not of the nodes)."""
    try:
        objects = json.loads(run(PW_DUMP) or "[]")
    except json.JSONDecodeError:
        return []
    clients = {
        o["id"]
        for o in objects
        if o.get("type") == "PipeWire:Interface:Client"
        and o.get("info", {}).get("props", {}).get("application.process.binary")
        == "snapclient"
    }
    return [
        o["id"]
        for o in objects
        if o.get("type") == "PipeWire:Interface:Node"
        and o.get("info", {}).get("props", {}).get("client.id") in clients
    ]


def get_volume(node: int) -> float | None:
    # "Volume: 0.40" or "Volume: 0.40 [MUTED]"
    parts = run(WPCTL, "get-volume", str(node)).split()
    try:
        return float(parts[1])
    except (IndexError, ValueError):
        return None


def set_volume(node: int, volume: float) -> None:
    run(WPCTL, "set-volume", str(node), f"{volume:.3f}")


async def fade(targets: dict[int, tuple[float, float]], seconds: float) -> None:
    """Move each node from its start to its end volume over `seconds`. Paced
    by the clock, since each wpctl call itself takes a while on a Pi 3."""
    loop = asyncio.get_running_loop()
    begin = loop.time()
    while True:
        t = min(1.0, (loop.time() - begin) / seconds) if seconds > 0 else 1.0
        for node, (start, end) in targets.items():
            set_volume(node, start + (end - start) * t)
        if t >= 1.0:
            return
        await asyncio.sleep(STEP)


def save_state(volumes: dict[int, float]) -> None:
    if not STATE_FILE:
        return
    if volumes:
        tmp = STATE_FILE + ".new"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({str(k): v for k, v in volumes.items()}, f)
        os.replace(tmp, STATE_FILE)
    else:
        try:
            os.remove(STATE_FILE)
        except FileNotFoundError:
            pass


def load_state() -> dict[int, float]:
    if not STATE_FILE:
        return {}
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return {int(k): float(v) for k, v in json.load(f).items()}
    except (FileNotFoundError, ValueError, json.JSONDecodeError):
        return {}


class Ducker:
    def __init__(self) -> None:
        self.saved: dict[int, float] = {}  # volume before the duck, per node
        self.rising: dict[int, float] = {}  # where a fade up is heading
        self.level: float | None = None  # fraction of the saved volume now
        self.task: asyncio.Task | None = None
        self.timeout: asyncio.TimerHandle | None = None

    @property
    def ducked(self) -> bool:
        return bool(self.saved)

    def _start(self, coro) -> None:
        # A new fade replaces one still running, from wherever it got to.
        if self.task and not self.task.done():
            self.task.cancel()
        self.task = asyncio.ensure_future(coro)

    def duck(self, level: float) -> None:
        if self.timeout:
            self.timeout.cancel()
        self.timeout = asyncio.get_running_loop().call_later(MAX_DUCK, self.restore)
        if self.ducked:
            if level != self.level:
                # Listening to speaking or back: from wherever it is now.
                self.level = level
                targets = {}
                for node, volume in self.saved.items():
                    now = get_volume(node)
                    if now is not None:
                        targets[node] = (now, volume * level)
                self._start(fade(targets, FADE_DOWN))
            return
        self.level = level
        targets = {}
        for node in snapcast_nodes():
            now = get_volume(node)
            if now is None:
                continue
            # Woken again while the music is still fading up: the volume to
            # return to is where that fade was heading, not where it got to.
            self.saved[node] = self.rising.get(node, now)
            targets[node] = (now, self.saved[node] * level)
        self.rising = {}
        save_state(self.saved)
        self._start(fade(targets, FADE_DOWN))

    def restore_now(self) -> None:
        """Put every stream straight back, without a fade (shutting down)."""
        for node, volume in {**self.rising, **self.saved}.items():
            set_volume(node, volume)
        self.saved, self.rising = {}, {}
        save_state({})

    def restore(self) -> None:
        if self.timeout:
            self.timeout.cancel()
            self.timeout = None
        if not self.ducked:
            return
        self.rising, self.saved = self.saved, {}
        self.level = None
        targets = {}
        for node, volume in self.rising.items():
            now = get_volume(node)
            if now is not None:  # the stream may have gone meanwhile
                targets[node] = (now, volume)
        self._start(self._rise(targets))

    async def _rise(self, targets: dict[int, tuple[float, float]]) -> None:
        await fade(targets, FADE_UP)
        self.rising = {}
        save_state({})


async def main_loop(ducker: Ducker) -> None:
    url = os.environ.get("LVA_PERIPHERAL_URL", "ws://127.0.0.1:6055")
    delay = 2.0

    while True:
        try:
            async with websockets.connect(url) as ws:
                delay = 2.0
                async for raw in ws:
                    try:
                        event = json.loads(raw).get("event")
                    except (json.JSONDecodeError, AttributeError):
                        continue
                    if event in LISTEN_EVENTS:
                        ducker.duck(DUCK_LISTEN_VOLUME)
                    elif event in SPEAK_EVENTS:
                        ducker.duck(DUCK_VOLUME)
                    elif event in RESTORE_EVENTS:
                        ducker.restore()
        except Exception as exc:  # pylint: disable=broad-except
            ducker.restore()
            print(f"lva-snapcast-duck: {exc}", file=sys.stderr)
            await asyncio.sleep(delay)
            delay = min(delay * 1.5, 30.0)


async def run_until_stopped() -> None:
    # Left down by an earlier run that didn't get to put them back.
    for node, volume in load_state().items():
        set_volume(node, volume)
    save_state({})

    ducker = Ducker()
    stopping = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stopping.set)
    task = asyncio.ensure_future(main_loop(ducker))
    await stopping.wait()
    task.cancel()
    ducker.restore_now()


def main() -> None:
    asyncio.run(run_until_stopped())


if __name__ == "__main__":
    main()

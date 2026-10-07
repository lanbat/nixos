#!/usr/bin/env python3
"""voice-id: a Wyoming speech-to-text proxy for Home Assistant's voice pipeline.

Home Assistant sends each utterance here instead of to faster-whisper; this
passes every event straight through to faster-whisper (the upstream) and the
transcript straight back, and reports itself to Home Assistant as "voice-id".

Phase A of speaker identification (docs/pi3-satellite.md): pass-through only,
logging how long the upstream took and how much the proxy added, so the cost
of sitting in the pipeline is measured before anything else is added to it.
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import time
from functools import partial

from wyoming.asr import Transcript
from wyoming.audio import AudioChunk, AudioStop
from wyoming.client import AsyncClient
from wyoming.event import Event
from wyoming.info import Attribution, Describe, Info
from wyoming.server import AsyncEventHandler, AsyncServer

_LOGGER = logging.getLogger("voice-id")

PROGRAM = "voice-id"


async def upstream_info(uri: str) -> Info:
    """The upstream's description, renamed so Home Assistant names the entity
    after this proxy (stt.voice_id), with the upstream's models and languages."""
    async with AsyncClient.from_uri(uri) as client:
        await client.write_event(Describe().event())
        while True:
            event = await client.read_event()
            if event is None:
                raise ConnectionError("upstream closed before describing itself")
            if Info.is_type(event.type):
                info = Info.from_event(event)
                break
    for program in info.asr:
        program.name = PROGRAM
        program.description = f"Speaker identification in front of {program.description or 'speech-to-text'}"
        program.attribution = Attribution(name="lanbat", url="https://github.com/lanbat/nixos")
    return info


class ProxyHandler(AsyncEventHandler):
    def __init__(self, upstream_uri: str, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.upstream_uri = upstream_uri
        self.upstream: AsyncClient | None = None
        self.pump: asyncio.Task | None = None
        self.audio_bytes = 0
        self.stopped_at: float | None = None

    async def handle_event(self, event: Event) -> bool:
        if Describe.is_type(event.type):
            await self.write_event((await upstream_info(self.upstream_uri)).event())
            return True

        if self.upstream is None:
            self.upstream = AsyncClient.from_uri(self.upstream_uri)
            await self.upstream.connect()
            self.pump = asyncio.create_task(self._pump())

        if AudioChunk.is_type(event.type):
            self.audio_bytes += len(event.payload or b"")
        elif AudioStop.is_type(event.type):
            self.stopped_at = time.monotonic()

        await self.upstream.write_event(event)
        return True

    async def _pump(self) -> None:
        """Every upstream event back to Home Assistant, until the transcript."""
        assert self.upstream is not None
        try:
            while True:
                event = await self.upstream.read_event()
                if event is None:
                    break
                received = time.monotonic()
                await self.write_event(event)
                if Transcript.is_type(event.type):
                    sent = time.monotonic()
                    upstream_ms = (received - self.stopped_at) * 1000 if self.stopped_at else -1
                    _LOGGER.info(
                        "transcript: upstream %.0f ms after the audio ended, proxy %.2f ms, %.1f s of audio",
                        upstream_ms,
                        (sent - received) * 1000,
                        self.audio_bytes / 32000,
                    )
                    break
        except Exception:  # pylint: disable=broad-except
            _LOGGER.exception("upstream failed")
        finally:
            await self._close_upstream()

    async def _close_upstream(self) -> None:
        if self.upstream is not None:
            try:
                await self.upstream.disconnect()
            except Exception:  # pylint: disable=broad-except
                pass
            self.upstream = None

    async def disconnect(self) -> None:
        if self.pump is not None:
            self.pump.cancel()
        await self._close_upstream()


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--uri", required=True, help="where Home Assistant connects, e.g. tcp://127.0.0.1:10303")
    parser.add_argument("--upstream", required=True, help="the speech-to-text server, e.g. tcp://127.0.0.1:10301")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO, format="%(message)s")

    server = AsyncServer.from_uri(args.uri)
    _LOGGER.info("listening on %s, passing through to %s", args.uri, args.upstream)
    await server.run(partial(ProxyHandler, args.upstream))


def run() -> None:
    asyncio.run(main())


if __name__ == "__main__":
    run()

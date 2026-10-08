"""T2: the local model decides, in a few tokens, what a request is.

Its answer is one line from a grammar ("act 3 off", "clarify", "escalate",
"reject"): the spike measured 2-6 generated tokens at about 1.4 s on
qwen3-4b against 2.8 s for the same decision as JSON. The device list is the
start of the prompt and changes only when the house does, so llama.cpp
keeps it cached; the room and the request come last.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass

import aiohttp

from .context import Context, Entity

DOMAINS = ("light", "switch", "fan", "cover", "media_player", "climate")
SWITCHING = {"on", "off", "toggle"}
MEDIA = {"pause", "play", "stop", "next", "volume_up", "volume_down", "volume_set"}
ALLOWED = {"light": SWITCHING, "switch": SWITCHING, "fan": SWITCHING, "climate": SWITCHING,
           "cover": {"open", "close"}, "media_player": MEDIA | {"on", "off"}}

GRAMMAR = r'''root ::= "act " num " " action (" " num)? | "clarify" | "escalate" | "reject"
num ::= [0-9] [0-9]? [0-9]?
action ::= "on" | "off" | "toggle" | "open" | "close" | "pause" | "play" | "stop" | "next" | "volume_up" | "volume_down" | "volume_set"'''

RULES = """You route voice commands for a home assistant. Reply with one line:
"act <device> <action> [value]", "clarify", "escalate" or "reject".
- act: a clear request to control one device you are sure of. "in here", "the light", "the TV" and media without a name mean the speaker's room.
- clarify: a device request that could mean several devices or doesn't say which.
- escalate: a question, a fact, a joke, news, music or a podcast to find, a reminder, an alarm, several devices, anything else.
- reject: not a request: background talk, TV or radio speech, fragments, nonsense, thanks.
Fix obvious mishearings using the device names.
Actions: on, off, toggle, open, close, pause, play, stop, next, volume_up, volume_down, volume_set (value 0-100).
Devices:
"""


@dataclass(frozen=True)
class Triage:
    route: str
    device: Entity | None = None
    action: str | None = None
    value: int | None = None


def controllable(ctx: Context) -> list[Entity]:
    return sorted((e for e in ctx.entities if e.domain in DOMAINS), key=lambda e: e.entity_id)


def local_prompt(entities: list[Entity]) -> str:
    return RULES + "\n".join(f"{i} {e.name} ({e.area or 'no room'})" for i, e in enumerate(entities))


def parse(line: str, entities: list[Entity]) -> Triage:
    parts = line.split()
    if not parts:
        return Triage("escalate")
    if parts[0] != "act":
        return Triage(parts[0]) if parts[0] in ("clarify", "escalate", "reject") else Triage("escalate")
    try:
        index, action = int(parts[1]), parts[2]
        value = int(parts[3]) if len(parts) > 3 else None
    except (IndexError, ValueError):
        return Triage("clarify")
    if not 0 <= index < len(entities):
        return Triage("clarify")
    device = entities[index]
    if action not in ALLOWED.get(device.domain, set()):
        return Triage("clarify")
    if action == "volume_set" and (value is None or not 0 <= value <= 100):
        return Triage("clarify")
    return Triage("act", device, action, value)


async def classify(session: aiohttp.ClientSession, url: str, model: str, ctx: Context, text: str,
                   timeout: float) -> Triage:
    entities = controllable(ctx)
    body = {
        "model": model, "temperature": 0, "max_tokens": 12, "cache_prompt": True, "grammar": GRAMMAR,
        "messages": [{"role": "system", "content": local_prompt(entities)},
                     {"role": "user", "content": f"The speaker is in {ctx.room or 'an unknown room'}. {text}"}],
    }
    try:
        async with session.post(url, json=body, timeout=aiohttp.ClientTimeout(total=timeout)) as r:
            r.raise_for_status()
            data = await r.json()
    except (aiohttp.ClientError, asyncio.TimeoutError):
        return Triage("escalate")
    return parse((data["choices"][0]["message"]["content"] or "").strip(), entities)

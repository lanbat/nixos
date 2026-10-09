"""A local decision as the tool calls Home Assistant's agent runs.

The functions are the ones setup-ha.sh gives the agent in router mode:
control_device(entity_id, action) and media_control(entity_id, action, value).
"""
from __future__ import annotations

import json
import uuid

from .triage import Triage

SERVICE = {"on": "turn_on", "off": "turn_off", "toggle": "toggle", "open": "open", "close": "close"}
MEDIA_SERVICE = {"pause": "media_pause", "play": "media_play", "stop": "media_stop", "next": "media_next_track",
                 "volume_up": "volume_up", "volume_down": "volume_down", "volume_set": "volume_set"}
SAID = {"pause": "Paused.", "play": "Playing.", "stop": "Stopped.", "next": "Next.",
        "volume_up": "Louder.", "volume_down": "Quieter."}


def tool_calls(t: Triage) -> list[dict]:
    assert t.route == "act" and t.device and t.action
    if t.action in MEDIA_SERVICE:
        name, args = "media_control", {"entity_id": t.device.entity_id, "action": MEDIA_SERVICE[t.action]}
        if t.value is not None:
            args["value"] = t.value
    else:
        name, args = "control_device", {"entity_id": t.device.entity_id, "action": SERVICE[t.action]}
    return [{"id": f"call_{uuid.uuid4().hex[:12]}", "type": "function",
             "function": {"name": name, "arguments": json.dumps(args)}}]


def done_phrase(t: Triage) -> str:
    if t.action in SAID:
        return SAID[t.action]
    if t.action == "volume_set":
        return f"Volume {t.value} percent."
    word = {"on": "on", "off": "off", "toggle": "switched", "open": "open", "close": "closed"}[t.action]
    return f"{t.device.name} {word}."

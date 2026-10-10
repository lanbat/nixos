"""Parse Frigate's MQTT messages into typed events.

Frigate publishes (see its MQTT docs):

- `frigate/tracked_object_update`: one message after each recognition
  attempt, for the object types it tracks. Only faces matter here; each has
  `type`, `id` (the event), `camera`, `name` (the best face-library match, or
  null) and `score` (0..1).
- `frigate/events`: a detection's lifecycle. Only `end`, once the object has
  an `end_time`, tells us a tracked face left the frame.
- `frigate/<camera>/status/detect`: camera health, `online`/`offline`/`disabled`.
- `frigate/available`: Frigate itself, `online`/`stopped`/`offline`.

Pure: no network, no side effects. Unit-tested against the documented shapes.
"""
from __future__ import annotations

import json
from dataclasses import dataclass


@dataclass(frozen=True)
class FaceUpdate:
    camera: str
    event_id: str
    name: str | None
    score: float
    timestamp: float


@dataclass(frozen=True)
class EventEnd:
    camera: str
    event_id: str


@dataclass(frozen=True)
class CameraStatus:
    camera: str
    online: bool


def _json(payload) -> dict | None:
    try:
        data = json.loads(payload)
    except (ValueError, TypeError):
        return None
    return data if isinstance(data, dict) else None


def parse_tracked_object_update(topic: str, payload) -> FaceUpdate | None:
    """`frigate/tracked_object_update` -> a FaceUpdate, for face objects only."""
    if topic != "frigate/tracked_object_update":
        return None
    data = _json(payload)
    if data is None or data.get("type") != "face":
        return None
    camera = data.get("camera")
    event_id = data.get("id")
    if not isinstance(camera, str) or not camera:
        return None
    if not isinstance(event_id, str) or not event_id:
        return None
    name = data.get("name")
    name = name if isinstance(name, str) and name else None
    score = data.get("score")
    if type(score) not in (int, float):
        return None
    ts = data.get("timestamp")
    ts = float(ts) if type(ts) in (int, float) else 0.0
    return FaceUpdate(camera=camera, event_id=event_id, name=name, score=float(score), timestamp=ts)


def parse_events(topic: str, payload) -> EventEnd | None:
    """`frigate/events` -> an EventEnd, once a detection has an end_time."""
    if topic != "frigate/events":
        return None
    data = _json(payload)
    if data is None or data.get("type") != "end":
        return None
    after = data.get("after")
    after = after if isinstance(after, dict) else {}
    # An `end` without an end_time is a placeholder, not "left the frame".
    if after.get("end_time") is None:
        return None
    camera = after.get("camera")
    event_id = after.get("id")
    if not isinstance(camera, str) or not camera:
        return None
    if not isinstance(event_id, str) or not event_id:
        return None
    return EventEnd(camera=camera, event_id=event_id)


def parse_camera_status(topic: str, payload) -> CameraStatus | None:
    """`frigate/<camera>/status/detect` -> whether that camera is usable."""
    prefix, suffix = "frigate/", "/status/detect"
    if not topic.startswith(prefix) or not topic.endswith(suffix):
        return None
    camera = topic[len(prefix):-len(suffix)]
    if not camera:
        return None
    value = payload if isinstance(payload, str) else str(payload).strip().lower()
    return CameraStatus(camera=camera, online=value == "online")


def parse_availability(payload) -> bool | None:
    """`frigate/available` -> whether Frigate is up, or None when unrecognised."""
    value = payload if isinstance(payload, str) else str(payload).strip().lower()
    return {"online": True, "stopped": False, "offline": False}.get(value)

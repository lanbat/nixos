"""Home Assistant MQTT payloads: discovery once, then retained state + events.

Each room gets a small set of entities that say who Frigate's camera sees: the
recognised name, how sure it is, whether anyone (and whether an enrolled
person) is present, and whether the camera is up. Discovery is published once
(retained) to `homeassistant/<component>/<entity>/config`; state is published
(retained) to `homelab/person/<room>/<field>`; each change also publishes an
event to `homelab/person_recognized`.
"""
from __future__ import annotations

EVENT_TOPIC = "homelab/person_recognized"


def _key(room: str) -> str:
    return (room or "").strip().replace(" ", "_") or "room"


def _state_base(room: str) -> str:
    return f"homelab/person/{_key(room)}"


def _discover(component: str, room: str, field: str, cfg: dict) -> tuple[str, dict]:
    return (
        f"homeassistant/{component}/{_key(room)}_{field}/config",
        cfg,
    )


def discovery_configs(room: str) -> list[tuple[str, dict]]:
    base = _state_base(room)
    uid = "lanbat_face_" + _key(room)
    return [
        _discover(
            "sensor",
            room,
            "person",
            {
                "name": f"{room} person",
                "state_topic": f"{base}/person",
                "unique_id": f"{uid}_person",
                "icon": "mdi:face",
            },
        ),
        _discover(
            "number",
            room,
            "confidence",
            {
                "name": f"{room} face confidence",
                "state_topic": f"{base}/confidence",
                "unique_id": f"{uid}_confidence",
                "min": 0,
                "max": 1,
                "step": 0.001,
                "icon": "mdi:percent",
            },
        ),
        _discover(
            "binary_sensor",
            room,
            "present",
            {
                "name": f"{room} person present",
                "state_topic": f"{base}/present",
                "unique_id": f"{uid}_present",
                "icon": "mdi:account-question",
            },
        ),
        _discover(
            "binary_sensor",
            room,
            "known",
            {
                "name": f"{room} person recognised",
                "state_topic": f"{base}/known",
                "unique_id": f"{uid}_known",
                "icon": "mdi:face-agent",
            },
        ),
        _discover(
            "binary_sensor",
            room,
            "camera",
            {
                "name": f"{room} camera",
                "state_topic": f"{base}/camera",
                "unique_id": f"{uid}_camera",
                "device_class": "connectivity",
            },
        ),
    ]


def state_values(room: str, faces: tuple, unknown: int, camera_online: bool) -> list[tuple[str, str]]:
    base = _state_base(room)
    top = max(faces, key=lambda f: f[1]) if faces else None
    person = top[0] if top else ("unknown" if unknown else "none")
    conf = f"{top[1]:.3f}" if top else "0.000"
    present = "ON" if (faces or unknown > 0) else "OFF"
    known = "ON" if top else "OFF"
    camera = "ON" if camera_online else "OFF"
    return [
        (f"{base}/person", person),
        (f"{base}/confidence", conf),
        (f"{base}/present", present),
        (f"{base}/known", known),
        (f"{base}/camera", camera),
    ]


def event_payload(room: str, faces: tuple, unknown: int, at: float) -> dict:
    top = max(faces, key=lambda f: f[1]) if faces else None
    return {
        "room": room,
        "person": top[0] if top else None,
        "confidence": top[1] if top else None,
        "known": top is not None,
        "unknown": unknown,
        "at": at,
    }

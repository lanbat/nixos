"""Who the assistant is talking to: a hint from voice, faces and phones.

Evidence arrives as (room, source, person key, confidence). The person keys
are the profile's people (lanbat.deployment.people); anything else is
dropped, so no free text from a satellite or a robot reaches a prompt. For a
request, the evidence in its room becomes one line for the cloud model:

- the voice of this request, if it matches someone well enough;
- faces at the room's robot, seen in the last FACE_SECONDS;
- phones in the room, seen over Bluetooth in the last PHONE_SECONDS.

Voice and face agreeing, or either alone, name the speaker; disagreeing, or
two faces without a voice, name nobody: unknown beats wrong. Phones only
say who is nearby. However sure, it is a hint for what the assistant says,
never authority over anything, and the line says so.
"""
from __future__ import annotations

from dataclasses import dataclass

SOURCES = ("face", "phone")
FACE_SECONDS = 10.0
PHONE_SECONDS = 120.0
WINDOW = {"face": FACE_SECONDS, "phone": PHONE_SECONDS}
VOICE_MIN = 0.7
FACE_MIN = 0.6
PHONE_MIN = 0.5


@dataclass
class Evidence:
    person: str
    confidence: float
    at: float


def _key(room: str) -> str:
    return (room or "").strip().casefold()


def _names(names: list[str]) -> str:
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


class People:
    def __init__(self, names: dict[str, str]) -> None:
        self.names = dict(names)
        # room -> source -> person -> evidence
        self._seen: dict[str, dict[str, dict[str, Evidence]]] = {}

    def add(self, key: str, name: str) -> None:
        self.names[str(key)] = str(name)

    def remove(self, key: str) -> None:
        self.names.pop(str(key), None)

    def observe(self, room: str, source: str, person: str, confidence, now: float) -> None:
        if source not in SOURCES or person not in self.names or not room:
            return
        if type(confidence) not in (int, float) or not 0 <= confidence <= 1:
            return
        self._seen.setdefault(_key(room), {}).setdefault(source, {})[person] = Evidence(
            person, float(confidence), now)

    def forget_faces(self, room: str) -> None:
        self._seen.get(_key(room), {}).pop("face", None)

    def _recent(self, room: str, source: str, now: float, minimum: float) -> list[str]:
        found = self._seen.get(_key(room), {}).get(source, {})
        return sorted(e.person for e in found.values()
                      if now - e.at <= WINDOW[source] and e.confidence >= minimum)

    def line(self, room: str, now: float, voice: tuple[str, float] | None = None) -> str | None:
        """The hint for a request from `room`, or None when nothing is known."""
        heard = voice[0] if voice and voice[0] in self.names and voice[1] >= VOICE_MIN else None
        faces = self._recent(room, "face", now, FACE_MIN)
        phones = self._recent(room, "phone", now, PHONE_MIN)

        speaker, how = None, ""
        if heard and (not faces or faces == [heard]):
            speaker, how = heard, "voice and face" if faces else "voice"
        elif not heard and len(faces) == 1:
            speaker, how = faces[0], "face"

        nearby = [p for p in dict.fromkeys(faces + phones) if p != speaker]
        if speaker is None and not nearby and not heard:
            return None

        parts = []
        if speaker:
            parts.append(f"You are probably talking to {self.names[speaker]} (recognised by {how}).")
        else:
            parts.append("You don't know who is speaking.")
        if nearby:
            names = [self.names[p] for p in nearby]
            parts.append(f"{_names(names)} {'is' if len(names) == 1 else 'are'} nearby.")
        parts.append("Recognition is a guess: use names to be friendly, never to decide or allow anything.")
        return " ".join(parts)

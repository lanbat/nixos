"""The mapper's state: who is in each room, from Frigate's face events.

Frigate tracks a face per camera per event: it emits a `tracked_object_update`
while the face is present (name = the best face-library match, or none) and an
`events` `end` when it leaves. A room's people are the distinct enrolled people
with a live face in that room's camera; a face with no enrolled match is counted
as unknown but never named. When the last live event for a person ends, that
person falls out of the room on their own.

Pure: the driver feeds it parsed events and reads snapshots; no I/O here.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class _Active:
    person: str | None
    score: float


@dataclass(frozen=True)
class RoomSnapshot:
    faces: tuple  # (("person", confidence), ...) for enrolled people, best score each
    unknown: int  # live faces with no enrolled match
    camera_online: bool


class PersonState:
    def __init__(self, registry: set[str], cameras: dict[str, str]) -> None:
        self.registry = set(registry)
        self.cameras = dict(cameras)  # camera -> room
        # camera -> event_id -> _Active
        self._active: dict[str, dict[str, _Active]] = {}
        self._online: dict[str, bool] = {}

    # -- events ---------------------------------------------------------------

    def on_face_update(self, camera: str, event_id: str, name, score: float) -> None:
        if camera not in self.cameras:
            return
        person = name if isinstance(name, str) and name in self.registry else None
        self._active.setdefault(camera, {})[event_id] = _Active(person, float(score))

    def on_event_end(self, camera: str, event_id: str) -> None:
        self._active.get(camera, {}).pop(event_id, None)

    def on_camera_status(self, camera: str, online: bool) -> None:
        if camera in self.cameras:
            self._online[camera] = online

    # -- read -----------------------------------------------------------------

    @property
    def rooms(self) -> tuple[str, ...]:
        return tuple(sorted(set(self.cameras.values())))

    def _room_cameras(self, room: str) -> list[str]:
        return [c for c, r in self.cameras.items() if r == room]

    def snapshot(self, room: str) -> RoomSnapshot:
        best: dict[str, float] = {}
        unknown = 0
        for cam in self._room_cameras(room):
            for act in self._active.get(cam, {}).values():
                if act.person is None:
                    unknown += 1
                else:
                    best[act.person] = max(best.get(act.person, 0.0), act.score)
        faces = tuple((p, round(s, 3)) for p, s in sorted(best.items()))
        online = any(self._online.get(c, False) for c in self._room_cameras(room))
        return RoomSnapshot(faces=faces, unknown=unknown, camera_online=online)

    def all_snapshots(self) -> dict[str, RoomSnapshot]:
        return {room: self.snapshot(room) for room in self.rooms}

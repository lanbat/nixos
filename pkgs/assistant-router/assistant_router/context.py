"""Home Assistant's side of a request, from the agent's system prompt.

setup-ha.sh writes the prompt as a context block rather than prose, so the
router knows the room the satellite is in, the time and the devices it may
control:

    LANBAT-CONTEXT v1
    room: <area of the satellite, or empty>
    device: <device id of the satellite, or empty>
    time: <ISO time>
    entities:
    <entity_id>|<spoken name>|<area>|<alias/alias>
    end
"""
from __future__ import annotations

from dataclasses import dataclass

MAGIC = "LANBAT-CONTEXT v1"


@dataclass(frozen=True)
class Entity:
    entity_id: str
    name: str
    area: str
    aliases: tuple[str, ...] = ()

    @property
    def domain(self) -> str:
        return self.entity_id.split(".", 1)[0]


@dataclass(frozen=True)
class Context:
    room: str
    device_id: str
    time: str
    entities: tuple[Entity, ...]


def parse_context(system_prompt: str) -> Context | None:
    lines = system_prompt.strip().splitlines()
    if not lines or lines[0].strip() != MAGIC:
        return None
    head: dict[str, str] = {}
    entities: list[Entity] = []
    in_entities = False
    for line in lines[1:]:
        if in_entities:
            if line.strip() == "end":
                break
            parts = line.split("|")
            if len(parts) < 2 or not parts[0].strip():
                continue
            aliases = tuple(a.strip() for a in (parts[3].split("/") if len(parts) > 3 else []) if a.strip())
            area = parts[2].strip() if len(parts) > 2 else ""
            entities.append(Entity(parts[0].strip(), parts[1].strip(), area, aliases))
        elif line.strip() == "entities:":
            in_entities = True
        elif ":" in line:
            key, _, value = line.partition(":")
            head[key.strip()] = value.strip()
    return Context(head.get("room", ""), head.get("device", ""), head.get("time", ""), tuple(entities))

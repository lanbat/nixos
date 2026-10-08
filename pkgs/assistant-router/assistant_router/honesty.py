"""What may be said: no claim of an action that no tool confirmed."""
from __future__ import annotations

import re

CLAIM = re.compile(r"\b(done|turned|turning|switched|switching|it's (on|off)|is now (on|off)|set (it |the )?to|"
                   r"paused|stopped|started|playing now|opened|closed|locked|unlocked|added)\b", re.I)
ENTITY_ID = re.compile(r"\b[a-z_]+\.[a-z0-9_]+\b")


def claims_action(text: str) -> bool:
    return bool(CLAIM.search(text or ""))


def speakable(text: str) -> str:
    t = (text or "").replace("**", "").replace("`", "").replace("#", "")
    t = ENTITY_ID.sub(lambda m: m.group(0).split(".", 1)[1].replace("_", " "), t)
    t = re.sub(r"(?<=[a-z0-9])_(?=[a-z0-9])", " ", t)
    t = re.sub(r"^\s*done[.!]\s*", "", t, flags=re.I)
    t = re.sub(r"\s*\bdone[.!]?\s*$", "", t, flags=re.I)
    return re.sub(r"\s+", " ", t).strip()


def check(text: str, tool_results: list[str]) -> str:
    if claims_action(text) and "Success" not in tool_results:
        return "I didn't change anything."
    return text

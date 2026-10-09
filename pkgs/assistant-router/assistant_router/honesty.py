"""What may be said: no claim of an action that no tool confirmed."""
from __future__ import annotations

import re

# A claim is the assistant saying it acted: a reply that opens with the
# action, "I turned...", "it's on.", "the lights are now off". The same verbs in
# an answer about the world ("the war started in 1939") are not claims.
VERBS = r"(turned|switched|turning|switching|set|paused|stopped|started|opened|closed|locked|unlocked|added|dimmed)"
CLAIM = re.compile(
    rf"^done\b|^{VERBS}\b|\bi('ve| have| just)? {VERBS}\b|"
    r"\b(is|are) now (on|off|open|closed|playing|paused|locked|unlocked)\b|\b(it's|it is) (on|off)[.!]?$", re.I)
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

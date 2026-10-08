"""What the router remembers between requests, in memory only.

The last reply per satellite lets the gate recognise the assistant's own
words picked up by the microphone. The tier per conversation keeps every
round of a turn on the model that started it: Home Assistant comes back with
tool results, and those belong to the cloud model that asked for the tools.
"""
from __future__ import annotations


class State:
    def __init__(self, echo_seconds: float = 30.0, turn_seconds: float = 120.0) -> None:
        self.echo_seconds = echo_seconds
        self.turn_seconds = turn_seconds
        self._replies: dict[str, tuple[float, str]] = {}
        self._tiers: dict[str, tuple[float, str]] = {}

    def remember_reply(self, device_id: str, text: str, now: float) -> None:
        if device_id and text:
            self._replies[device_id] = (now, text)

    def last_reply(self, device_id: str, now: float) -> str:
        at, text = self._replies.get(device_id, (0.0, ""))
        return text if text and now - at <= self.echo_seconds else ""

    def set_tier(self, conversation_id: str, tier: str, now: float) -> None:
        if conversation_id:
            self._tiers[conversation_id] = (now, tier)

    def tier(self, conversation_id: str, now: float) -> str | None:
        at, tier = self._tiers.get(conversation_id, (0.0, ""))
        return tier if tier and now - at <= self.turn_seconds else None

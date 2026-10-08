"""What the router remembers between requests, in memory only.

The last reply per satellite lets the gate recognise the assistant's own
words picked up by the microphone. A local act waits by the id of the tool
call Home Assistant runs for it, until Home Assistant comes back with that
call's result; if the call fails, Home Assistant never does, and the entry
expires.
"""
from __future__ import annotations

from typing import Any


class State:
    def __init__(self, echo_seconds: float = 30.0, pending_seconds: float = 60.0) -> None:
        self.echo_seconds = echo_seconds
        self.pending_seconds = pending_seconds
        self._replies: dict[str, tuple[float, str]] = {}
        self._pending: dict[str, tuple[float, Any]] = {}

    def remember_reply(self, device_id: str, text: str, now: float) -> None:
        if device_id and text:
            self._replies[device_id] = (now, text)

    def last_reply(self, device_id: str, now: float) -> str:
        at, text = self._replies.get(device_id, (0.0, ""))
        return text if text and now - at <= self.echo_seconds else ""

    def add_pending(self, call_id: str, value: Any, now: float) -> None:
        self._pending = {k: v for k, v in self._pending.items() if now - v[0] <= self.pending_seconds}
        self._pending[call_id] = (now, value)

    def take_pending(self, call_ids: list[str], now: float) -> Any:
        for call_id in call_ids:
            at, value = self._pending.pop(call_id, (0.0, None))
            if value is not None and now - at <= self.pending_seconds:
                return value
        return None

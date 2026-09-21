"""Per-resource results. 'skipped' is first-class: it is how honestly
unsupported or unverifiable state is reported instead of a false 'ok'."""
from __future__ import annotations

from dataclasses import dataclass

OK = "ok"
CHANGED = "changed"
SKIPPED = "skipped"
FAILED = "failed"


@dataclass(frozen=True)
class Outcome:
    resource: str
    target: str
    status: str
    reason: str | None = None

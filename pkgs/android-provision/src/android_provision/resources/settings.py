"""settings get / settings put, verified by reading back.

Some protected keys accept a write and silently do not change; the verify
step turns that into 'failed' rather than a false 'ok'.
"""
from __future__ import annotations

from ..adb import Adb, AdbError, DeviceInfo
from ..manifest import Manifest
from ..outcome import CHANGED, FAILED, OK, Outcome


def _get(adb: Adb, ns: str, key: str) -> str | None:
    value = adb.shell("settings", "get", ns, key)
    return None if value in ("null", "") else value


def reconcile(
    adb: Adb, info: DeviceInfo, manifest: Manifest, *, apply: bool, force: bool
) -> list[Outcome]:
    outcomes: list[Outcome] = []
    for ns, table in sorted(manifest.settings.items()):
        for key, desired in sorted(table.items()):
            outcomes.append(_one(adb, ns, key, desired, apply=apply, force=force))
    return outcomes


def _one(adb: Adb, ns: str, key: str, desired: str, *, apply: bool, force: bool) -> Outcome:
    target = f"{ns}/{key}"
    current = _get(adb, ns, key)

    if current == desired and not force:
        return Outcome("setting", target, OK)
    if not apply:
        return Outcome("setting", target, CHANGED, f"would set {current!r} -> {desired!r}")

    try:
        adb.shell("settings", "put", ns, key, desired)
    except AdbError as exc:
        return Outcome("setting", target, FAILED, str(exc))

    if _get(adb, ns, key) != desired:
        return Outcome(
            "setting", target, FAILED,
            f"write did not take; {key} is still {current!r} "
            "(the key is probably protected on this device)",
        )
    return Outcome("setting", target, CHANGED)

"""The default home screen: cmd package set-home-activity, verified by reading
back, because a box can refuse the change and still exit 0."""
from __future__ import annotations

from ..adb import Adb, AdbError, DeviceInfo
from ..manifest import Manifest
from ..outcome import CHANGED, FAILED, OK, Outcome

RESOLVE_HOME = (
    "cmd", "package", "resolve-activity", "--brief",
    "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME",
)


def current_home(adb: Adb) -> str | None:
    lines = [line.strip() for line in adb.shell(*RESOLVE_HOME).splitlines() if line.strip()]
    if not lines or "/" not in lines[-1]:
        return None
    return lines[-1]


def _full(component: str) -> str:
    package, _, activity = component.partition("/")
    if activity.startswith("."):
        activity = package + activity
    return f"{package}/{activity}"


def same_component(a: str, b: str) -> bool:
    return _full(a) == _full(b)


def reconcile(
    adb: Adb, info: DeviceInfo, manifest: Manifest, *, apply: bool, force: bool
) -> list[Outcome]:
    desired = manifest.homeActivity
    if desired is None:
        return []
    current = current_home(adb)
    if current is not None and same_component(current, desired) and not force:
        return [Outcome("home", desired, OK)]
    if not apply:
        return [Outcome("home", desired, CHANGED, f"would change home from {current!r}")]
    try:
        reply = adb.shell("cmd", "package", "set-home-activity", desired)
    except AdbError as exc:
        return [Outcome("home", desired, FAILED, str(exc))]
    after = current_home(adb)
    if after is None or not same_component(after, desired):
        return [Outcome("home", desired, FAILED, f"home is still {after!r}: {reply}")]
    return [Outcome("home", desired, CHANGED)]

"""Compare two snapshots. Run on a freshly reset box against a snapshot taken
before the reset, it prints exactly what the reset lost, and the settings to
put back as a fragment for androidDevices.<box>."""
from __future__ import annotations

from dataclasses import dataclass, field

from .manifest import NAMESPACES
from .resources.home import same_component

# Keys that change by themselves or identify one installation; restoring them
# is meaningless. Extend from what the hardware run shows (docs/android-devices.md).
VOLATILE: dict[str, str] = {
    "global/boot_count": "counts boots",
    "global/device_provisioned": "set by the setup wizard",
    "secure/android_id": "identifies one installation",
    "secure/bluetooth_address": "hardware identity",
    "secure/user_setup_complete": "set by the setup wizard",
}


@dataclass(frozen=True)
class Change:
    ns: str
    key: str
    old: str | None
    new: str | None


@dataclass
class Diff:
    settings: list[Change] = field(default_factory=list)
    apps_missing: list[str] = field(default_factory=list)
    apps_added: list[str] = field(default_factory=list)
    apps_version: list[tuple[str, int | None, int | None]] = field(default_factory=list)
    home: tuple[str | None, str | None] | None = None


def compare(old: dict, new: dict, ignore: frozenset[str] = frozenset()) -> Diff:
    d = Diff()
    for ns in NAMESPACES:
        a, b = old["settings"].get(ns, {}), new["settings"].get(ns, {})
        for key in sorted(set(a) | set(b)):
            name = f"{ns}/{key}"
            if name in VOLATILE or name in ignore or a.get(key) == b.get(key):
                continue
            d.settings.append(Change(ns, key, a.get(key), b.get(key)))
    pa, pb = old["packages"], new["packages"]
    d.apps_missing = sorted(set(pa) - set(pb))
    d.apps_added = sorted(set(pb) - set(pa))
    d.apps_version = [
        (p, pa[p]["versionCode"], pb[p]["versionCode"])
        for p in sorted(set(pa) & set(pb))
        if pa[p]["versionCode"] != pb[p]["versionCode"]
    ]
    ha, hb = old.get("home"), new.get("home")
    if (ha is None) != (hb is None) or (ha and hb and not same_component(ha, hb)):
        d.home = (ha, hb)
    return d


def _nix(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${")
    return f'"{escaped}"'


def restore_fragment(d: Diff) -> str:
    lines = ["# For androidDevices.<box>; review before pasting."]
    restorable = [c for c in d.settings if c.old is not None]
    if restorable:
        lines.append("settings = {")
        for ns in NAMESPACES:
            changes = [c for c in restorable if c.ns == ns]
            if changes:
                lines.append(f"  {ns} = {{")
                lines += [f"    {_nix(c.key)} = {_nix(c.old)};" for c in changes]
                lines.append("  };")
        lines.append("};")
    if d.home and d.home[0]:
        lines.append(f"homeActivity = {_nix(d.home[0])};")
    new_only = [c for c in d.settings if c.old is None]
    for c in new_only:
        lines.append(f"# {c.ns}/{c.key} exists only on the new box ({c.new!r}); settings put can't remove it")
    return "\n".join(lines) + "\n"


def render(d: Diff) -> str:
    out: list[str] = []
    for c in d.settings:
        out.append(f"setting {c.ns}/{c.key}: {c.old!r} -> {c.new!r}")
    out += [f"app missing: {p}" for p in d.apps_missing]
    out += [f"app added: {p}" for p in d.apps_added]
    out += [f"app version {p}: {a} -> {b}" for p, a, b in d.apps_version]
    if d.home:
        out.append(f"home: {d.home[0]!r} -> {d.home[1]!r}")
    return "\n".join(out) + "\n" if out else "no differences\n"

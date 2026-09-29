"""A read-only record of a box: its user-installed apps, every setting, and
the home screen. Two snapshots, before and after a reset, show exactly what a
reset loses (diff.py)."""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

from .adb import Adb, DeviceInfo
from .manifest import NAMESPACES
from .resources.home import current_home

SCHEMA = 1


class SnapshotError(Exception):
    """A snapshot file is unreadable or from another schema."""


def parse_packages(text: str) -> dict[str, dict]:
    packages: dict[str, dict] = {}
    for line in text.splitlines():
        if not line.startswith("package:"):
            continue
        tokens = line[len("package:"):].split()
        entry: dict = {"versionCode": None, "installer": None}
        for token in tokens[1:]:
            if token.startswith("versionCode:"):
                entry["versionCode"] = int(token.split(":", 1)[1])
            elif token.startswith("installer="):
                value = token.split("=", 1)[1]
                entry["installer"] = None if value == "null" else value
        packages[tokens[0]] = entry
    return packages


def parse_settings(text: str) -> dict[str, str]:
    table: dict[str, str] = {}
    last: str | None = None
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key and " " not in key:
            table[key] = value
            last = key
        elif last is not None:
            # A value spanning lines: settings list prints it verbatim.
            table[last] += "\n" + line
    return table


def take(adb: Adb, info: DeviceInfo, *, device: str) -> dict:
    return {
        "schema": SCHEMA,
        "device": device,
        "taken": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ"),
        "model": info.model,
        "sdk": info.sdk,
        "abis": info.abis,
        "packages": parse_packages(
            adb.shell("pm", "list", "packages", "-3", "-i", "--show-versioncode")
        ),
        "settings": {ns: parse_settings(adb.shell("settings", "list", ns)) for ns in NAMESPACES},
        "home": current_home(adb),
    }


def save(snap: dict, out_dir: str) -> Path:
    directory = Path(out_dir)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / f"{snap['taken']}.json"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(snap, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return path


def load(path: str) -> dict:
    try:
        with open(path) as fh:
            snap = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        raise SnapshotError(f"cannot read snapshot {path}: {exc}") from exc
    if not isinstance(snap, dict):
        raise SnapshotError(f"{path} is not a snapshot (top level is {type(snap).__name__}, not an object)")
    if snap.get("schema") != SCHEMA:
        raise SnapshotError(f"{path} is snapshot schema {snap.get('schema')!r}, expected {SCHEMA}")
    return snap

"""Where each app on a captured box can come from, as a fragment for
androidDevices.<box>: the lockfile, F-Droid, or neither (Play Store apps and
unknowns are listed for the maintainer)."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

PLAY_STORE = "com.android.vending"


@dataclass(frozen=True)
class Proposal:
    packageId: str
    kind: str
    detail: str


def default_lockfile() -> str:
    # Installed layout: $out/lib/android_provision/sources.py and
    # $out/share/android-provision/apks.lock.json.
    return str(Path(__file__).resolve().parents[2] / "share/android-provision/apks.lock.json")


def load_lock(path: str) -> dict:
    with open(path) as fh:
        return json.load(fh)


def propose(packages: dict, lock: dict, fdroid: dict | None) -> list[Proposal]:
    by_package = {entry["packageId"]: (key, entry) for key, entry in lock.items()}
    proposals = []
    for package_id in sorted(packages):
        installer = packages[package_id].get("installer")
        if package_id in by_package:
            key, entry = by_package[package_id]
            if entry["source"] == "github":
                url = next(iter(entry["variants"].values()))["url"]
                proposals.append(Proposal(package_id, "lockfile-github", f"{key}|{url.rsplit('/', 1)[1]}"))
            else:
                proposals.append(Proposal(package_id, "lockfile-fdroid", key))
        elif fdroid is not None and package_id in fdroid.get("packages", {}):
            proposals.append(Proposal(package_id, "fdroid", package_id))
        elif installer == PLAY_STORE:
            proposals.append(Proposal(package_id, "play", package_id))
        else:
            proposals.append(Proposal(package_id, "unknown", package_id))
    return proposals


def fragment(proposals: list[Proposal]) -> str:
    fdroid = [p.detail for p in proposals if p.kind in ("lockfile-fdroid", "fdroid")]
    github = [p.detail.split("|") for p in proposals if p.kind == "lockfile-github"]
    lines = ["# For androidDevices.<box>. New F-Droid ids also need: nix run .#android-update"]
    if fdroid:
        lines.append("packages = [ " + " ".join(f'"{p}"' for p in fdroid) + " ];")
    if github:
        lines.append("github = [")
        lines += [f'  {{ repo = "{repo}"; asset = "{asset}"; }}' for repo, asset in github]
        lines.append("];")
    lines += [f"# Play Store: {p.packageId}" for p in proposals if p.kind == "play"]
    lines += [f"# no known source: {p.packageId} (add a GitHub repo or an Obtainium URL)"
              for p in proposals if p.kind == "unknown"]
    return "\n".join(lines) + "\n"

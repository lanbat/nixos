"""Hand Obtainium its URL list. Never installs the apps it tracks.

The reference box has no DocumentsUI, so every Storage Access Framework file
picker fails -- which rules out Obtainium's file-based import. This ships the
designed fallback from the spec: push the list and print it for manual entry
into 'Import from URL list', which is a plain text field. Spike 2 may replace
this with an obtainium:// deep link or 'input text'.

Obtainium owns updates for these apps; Nix owns packages and github entries.
"""
from __future__ import annotations

from ..adb import Adb, AdbError, DeviceInfo
from ..manifest import Manifest
from ..outcome import CHANGED, FAILED, OK, Outcome

REMOTE_DIR = "/sdcard/Download"


def reconcile(
    adb: Adb, info: DeviceInfo, manifest: Manifest, *, apply: bool, force: bool
) -> list[Outcome]:
    entry = manifest.obtainium
    if entry is None:
        return []

    marker = f"obtainium/{entry.sha256}"
    if not force and adb.marker_exists(marker):
        return [Outcome("obtainium", "url-list", OK)]

    if not apply:
        return [Outcome("obtainium", "url-list", CHANGED, "would push the URL list")]

    remote = f"{REMOTE_DIR}/obtainium-urls.txt"
    try:
        adb.push(entry.path, remote)
        adb.write_marker(marker)
    except AdbError as exc:
        return [Outcome("obtainium", "url-list", FAILED, str(exc))]

    with open(entry.path) as fh:
        urls = [line.strip() for line in fh if line.strip()]

    return [
        Outcome(
            "obtainium", "url-list", CHANGED,
            f"pushed {len(urls)} URLs to {remote}; add them on the box via "
            "Obtainium > Import/Export > 'Import from URL list':\n    "
            + "\n    ".join(urls),
        )
    ]

"""Install an internal CA into the user trust store.

Two hard limits on an unrooted Android 14 user build, both from the spec:

  * There is no adb command that installs a CA silently. The cert is pushed
    and the install intent is launched; the final confirmation is on-screen.
  * /data/misc/user/0/cacerts-added/ is unreadable without root, so we cannot
    verify the trust store. Idempotency is marker-backed: self-reported state,
    not proof. --force re-applies.

And the limit no install can lift: since Android 7, apps ignore user CAs
unless they opt in. This fixes the browser. It does not fix Kodi, Jellyfin
or YouTube.
"""
from __future__ import annotations

from ..adb import Adb, AdbError, DeviceInfo
from ..manifest import CaCert, Manifest
from ..outcome import CHANGED, FAILED, OK, Outcome

REMOTE_DIR = "/sdcard/Download"
INSTALL_ACTION = "android.credentials.INSTALL"


def reconcile(
    adb: Adb, info: DeviceInfo, manifest: Manifest, *, apply: bool, force: bool
) -> list[Outcome]:
    return [_one(adb, cert, apply=apply, force=force) for cert in manifest.caCerts]


def _one(adb: Adb, cert: CaCert, *, apply: bool, force: bool) -> Outcome:
    marker = f"cacerts/{cert.sha256}"

    if not force and adb.marker_exists(marker):
        return Outcome("cacert", cert.name, OK)

    if not apply:
        return Outcome("cacert", cert.name, CHANGED, "would push and launch the installer")

    remote = f"{REMOTE_DIR}/{cert.name}.crt"
    try:
        adb.push(cert.path, remote)
        adb.shell("am", "start", "-a", INSTALL_ACTION, "-t", "application/x-x509-ca-cert",
                  "-d", f"file://{remote}")
        adb.write_marker(marker)
    except AdbError as exc:
        return Outcome("cacert", cert.name, FAILED, str(exc))

    return Outcome(
        "cacert", cert.name, CHANGED,
        "pushed and installer launched; confirm on-screen on the box. "
        "Apps must still opt in to user CAs (Android 7+), so this fixes the "
        "browser and not Kodi/Jellyfin/YouTube",
    )

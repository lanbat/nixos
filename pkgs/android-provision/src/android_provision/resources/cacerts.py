"""Install an internal CA into the user trust store.

Hard limits on an unrooted user build:

  * There is no adb command that installs a CA silently. Below Android 11 the
    cert is pushed and the install intent is launched; the final confirmation
    is on-screen.
  * From Android 11 the install intent no longer opens for CA certificates:
    they install only from Settings, which Android TV's Settings may lack
    entirely. The cert is delivered to Download, for Settings or for an app
    with its own certificate import (Argosy), and nothing is launched.
  * /data/misc/user/0/cacerts-added/ is unreadable without root, so we cannot
    verify the trust store. Below Android 11 idempotency is marker-backed:
    self-reported state, not proof. From Android 11 only the delivered file
    is checked. --force re-applies.

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
# The reference box (Android 14) refuses the intent with START result -91 and
# shows nothing.
DIALOG_REFUSED_FROM_SDK = 30


def reconcile(
    adb: Adb, info: DeviceInfo, manifest: Manifest, *, apply: bool, force: bool
) -> list[Outcome]:
    if info.sdk >= DIALOG_REFUSED_FROM_SDK:
        return [_deliver(adb, cert, apply=apply, force=force) for cert in manifest.caCerts]
    return [_one(adb, cert, apply=apply, force=force) for cert in manifest.caCerts]


def _remote_path(cert: CaCert) -> str:
    # cert.name is `baseNameOf` the cert path on the Nix side, which already
    # includes its extension (e.g. "caddy-ca-root.crt"). Strip a trailing
    # .crt before appending one, so the remote filename never ends up
    # "caddy-ca-root.crt.crt".
    stem = cert.name[:-4] if cert.name.lower().endswith(".crt") else cert.name
    return f"{REMOTE_DIR}/{stem}.crt"


def _deliver(adb: Adb, cert: CaCert, *, apply: bool, force: bool) -> Outcome:
    """Android 11+: put the file where Settings and apps can pick it up, and
    say so. Whether a CA is installed can't be read, so it isn't claimed."""
    remote = _remote_path(cert)
    how = (
        f"{remote}: install it from Settings (Security > Encryption & credentials > "
        "Install a certificate > CA certificate), or import it in an app with its "
        "own certificate import such as Argosy; Android 11+ can't open the install "
        "dialog from adb, and Android TV's Settings may have no certificate screen"
    )
    if not force and adb.shell_ok("test", "-f", remote):
        return Outcome("cacert", cert.name, OK, f"delivered to {how}")
    if not apply:
        return Outcome("cacert", cert.name, CHANGED, f"would deliver to {how}")
    try:
        adb.push(cert.path, remote)
    except AdbError as exc:
        return Outcome("cacert", cert.name, FAILED, str(exc))
    return Outcome("cacert", cert.name, CHANGED, f"delivered to {how}")


def _one(adb: Adb, cert: CaCert, *, apply: bool, force: bool) -> Outcome:
    marker = f"cacerts/{cert.sha256}"

    if not force and adb.marker_exists(marker):
        return Outcome("cacert", cert.name, OK)

    if not apply:
        return Outcome("cacert", cert.name, CHANGED, "would push and launch the installer")

    remote = _remote_path(cert)
    try:
        adb.push(cert.path, remote)
        output = adb.shell(
            "am", "start", "-a", INSTALL_ACTION, "-t", "application/x-x509-ca-cert",
            "-d", f"file://{remote}",
        )
    except AdbError as exc:
        return Outcome("cacert", cert.name, FAILED, str(exc))

    # `am start` exits 0 even when nothing resolves the intent -- it only
    # says so on stdout. This is the one resource whose real state can't be
    # read back afterwards, so a failed launch must never self-certify by
    # writing the marker.
    if any(line.startswith("Error:") for line in output.splitlines()):
        return Outcome(
            "cacert", cert.name, FAILED,
            f"install intent did not resolve: {output.strip()}",
        )

    try:
        adb.write_marker(marker)
    except AdbError as exc:
        return Outcome("cacert", cert.name, FAILED, str(exc))

    return Outcome(
        "cacert", cert.name, CHANGED,
        "pushed and installer launched; confirm on-screen on the box. "
        "Apps must still opt in to user CAs (Android 7+), so this fixes the "
        "browser and not Kodi/Jellyfin/YouTube",
    )

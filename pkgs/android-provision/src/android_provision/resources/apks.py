"""Install APKs pinned by apks.lock.json. Never uninstalls anything."""
from __future__ import annotations

import re

from ..adb import Adb, AdbError, DeviceInfo
from ..manifest import Apk, Manifest
from ..outcome import CHANGED, FAILED, OK, SKIPPED, Outcome

VERSION_CODE = re.compile(r"versionCode=(\d+)")


def installed_version(adb: Adb, package_id: str) -> int | None:
    out = adb.shell("dumpsys", "package", package_id)
    match = VERSION_CODE.search(out)
    return int(match.group(1)) if match else None


def reconcile(
    adb: Adb, info: DeviceInfo, manifest: Manifest, *, apply: bool, force: bool
) -> list[Outcome]:
    return [_one(adb, info, manifest, apk, apply=apply, force=force) for apk in manifest.apks]


def _one(
    adb: Adb, info: DeviceInfo, manifest: Manifest, apk: Apk, *, apply: bool, force: bool
) -> Outcome:
    target = apk.packageId

    if apk.minSdk > info.sdk:
        return Outcome("apk", target, SKIPPED, f"minSdk {apk.minSdk} > device {info.sdk}")

    if manifest.abi not in info.abis:
        return Outcome(
            "apk", target, SKIPPED,
            f"configured abi {manifest.abi!r} not supported by device "
            f"(device reports: {', '.join(info.abis) or 'none'})",
        )

    current = installed_version(adb, target)
    downgrade = False

    if current is not None:
        if current == apk.versionCode and not force:
            return Outcome("apk", target, OK)
        if current > apk.versionCode:
            if not manifest.allowDowngrade:
                return Outcome(
                    "apk", target, SKIPPED,
                    f"newer installed ({current} > {apk.versionCode}); "
                    "set allowDowngrade to replace it",
                )
            downgrade = True

    if not apply:
        return Outcome("apk", target, CHANGED, "would install")

    try:
        adb.install(apk.path, downgrade=downgrade)
    except AdbError as exc:
        return Outcome("apk", target, FAILED, str(exc))

    verified = installed_version(adb, target)
    if verified != apk.versionCode:
        return Outcome(
            "apk", target, FAILED,
            f"installed but reports versionCode {verified}, expected {apk.versionCode}",
        )
    return Outcome("apk", target, CHANGED)

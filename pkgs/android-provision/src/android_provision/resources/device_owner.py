"""Set a Device Owner via dpm. Opt-in, and never resets anything.

A device owner can only be set on a box with no configured accounts, which in
practice means immediately after a factory reset. That reset is the operator's
deliberate act; this code will not perform one.

Ordered after APK install so the DPC package exists on the device.
"""
from __future__ import annotations

import re

from ..adb import Adb, AdbError, DeviceInfo
from ..manifest import Manifest
from ..outcome import CHANGED, FAILED, OK, Outcome

# Real `dumpsys device_policy` prints a multi-line block, e.g.:
#     Device Owner:
#       admin=ComponentInfo{com.example.dpc/com.example.dpc.AdminReceiver}
#       name=Example
#       package=com.example.dpc
# Anchoring on "Device Owner:" with \s* crossing the newline captures
# "admin=ComponentInfo{...}" instead of the component -- anchor on
# ComponentInfo{...} itself instead, which is absent when no owner is set.
OWNER = re.compile(r"ComponentInfo\{([^}]+)\}")


def current_owner(adb: Adb) -> str | None:
    match = OWNER.search(adb.shell("dumpsys", "device_policy"))
    return match.group(1) if match else None


def reconcile(
    adb: Adb, info: DeviceInfo, manifest: Manifest, *, apply: bool, force: bool
) -> list[Outcome]:
    desired = manifest.deviceOwner
    if not desired.enable:
        return []

    target = desired.component
    existing = current_owner(adb)

    if existing == target:
        return [Outcome("deviceOwner", target, OK)]
    if existing is not None:
        return [
            Outcome("deviceOwner", target, FAILED,
                    f"owner already set to {existing}; a device owner cannot be "
                    "replaced without a factory reset")
        ]
    if not apply:
        return [Outcome("deviceOwner", target, CHANGED, "would set device owner")]

    try:
        adb.shell("dpm", "set-device-owner", target)
    except AdbError as exc:
        message = str(exc)
        if "accounts on the device" in message:
            return [
                Outcome("deviceOwner", target, FAILED,
                        "accounts are configured on the device; a device owner can "
                        "only be set on a box with none, i.e. after a factory reset")
            ]
        return [Outcome("deviceOwner", target, FAILED, message)]

    if current_owner(adb) != target:
        return [Outcome("deviceOwner", target, FAILED, "dpm reported success but no owner is set")]
    return [Outcome("deviceOwner", target, CHANGED)]

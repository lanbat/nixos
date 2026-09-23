#!/usr/bin/env python3
"""Set the clock on Xiaomi BLE thermometers that have a display.

LYWSD02/LYWSD02MMC keep time in a GATT characteristic and have no way to set it
themselves: no NTP, no radio signal, no RTC sync.  The Mi Home app wrote the
value whenever it was opened, so a device that is not bound to Mi Home -- which
is the point of running it locally -- free-runs, and ships from the factory on
UTC+8.

The characteristic takes five bytes:

    [0:4]  uint32, little endian, plain UTC Unix epoch (not local-adjusted)
    [4]    int8, offset from UTC in hours; bit 7 selects 12-hour display

Bit 7 is left clear here, so the display stays on 24-hour time.  The offset is
read from the system timezone on every run, which is what makes a daylight
saving change correct itself.

These are sleepy peripherals: they advertise every few seconds and a connection
can only be established during an advertising window, so the connect timeout is
generous and failures are expected rather than exceptional.  A device that is
out of range or asleep is logged and skipped; the timer tries again later.
"""

import asyncio
import os
import re
import struct
import sys
import time

from bleak import BleakClient
from bleak.exc import BleakError

# ebe0ccb7 in service ebe0ccb0-7a0a-4b0c-8a1a-6ff2997da3a6.
TIME_CHARACTERISTIC = "ebe0ccb7-7a0a-4b0c-8a1a-6ff2997da3a6"

MAC_RE = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")

CONNECT_TIMEOUT = float(os.environ.get("XIAOMI_CLOCK_TIMEOUT", "180"))
ATTEMPTS = int(os.environ.get("XIAOMI_CLOCK_ATTEMPTS", "3"))
RETRY_DELAY = float(os.environ.get("XIAOMI_CLOCK_RETRY_DELAY", "15"))


def log(message):
    print(f"xiaomi-clock-sync: {message}", flush=True)


def utc_offset_hours():
    """Whole hours east of UTC for the current local time, DST included."""
    if time.daylight and time.localtime().tm_isdst > 0:
        seconds = -time.altzone
    else:
        seconds = -time.timezone
    return seconds // 3600


def configured_devices():
    raw = os.environ.get("XIAOMI_CLOCK_DEVICES", "")
    devices = []
    for token in raw.split():
        if MAC_RE.match(token):
            devices.append(token.upper())
        elif token:
            log(f"ignoring malformed address {token!r}")
    return devices


async def set_clock(address):
    """Return True when the device's clock was set or it has no clock."""
    async with BleakClient(address, timeout=CONNECT_TIMEOUT) as client:
        offset = utc_offset_hours()
        payload = struct.pack("<Ib", int(time.time()), offset)
        try:
            await client.write_gatt_char(TIME_CHARACTERISTIC, payload, response=True)
        except BleakError as exc:
            # Xiaomi BLE devices without a display -- an LYWSD03MMC, a sensor --
            # simply do not carry this characteristic.  Nothing to do for them.
            if "not found" in str(exc).lower():
                log(f"{address}: no clock characteristic, skipping")
                return True
            raise
        local = time.strftime("%Y-%m-%d %H:%M:%S %Z")
        log(f"{address}: set to {local} (UTC{offset:+d})")
        return True


async def main():
    devices = configured_devices()
    if not devices:
        log("no devices configured, nothing to do")
        return 0

    for address in devices:
        for attempt in range(1, ATTEMPTS + 1):
            try:
                await set_clock(address)
                break
            except Exception as exc:  # noqa: BLE001 - any failure is a retry
                reason = type(exc).__name__ if not str(exc) else exc
                log(f"{address}: attempt {attempt}/{ATTEMPTS} failed: {reason}")
                if attempt < ATTEMPTS:
                    await asyncio.sleep(RETRY_DELAY)
                else:
                    log(f"{address}: unreachable, leaving it for the next run")

    # Always succeed: an asleep or out-of-range thermometer is normal and must
    # not show up as a failed unit.
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

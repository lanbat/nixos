"""Switch the TV between the Kodi and games sessions from any controller.

Holding the Guide (Xbox) button for 2 seconds, or Select and Start together
for 3 seconds, runs `tv-switch toggle`. It reads the input devices directly,
so it works whatever the session on screen is doing, even with a frozen
emulator. The tv-switch path comes from the TV_SWITCH environment variable.
"""

import asyncio
import os

import evdev
from evdev import ecodes

# Buttons held together, and for how many seconds.
COMBOS = [
    ({ecodes.BTN_MODE}, 2.0),  # Xbox Guide button
    ({ecodes.BTN_SELECT, ecodes.BTN_START}, 3.0),  # gamepads
    ({ecodes.BTN_BASE3, ecodes.BTN_BASE4}, 3.0),  # USB arcade encoders (buttons 9 and 10)
]
WANTED = set().union(*(buttons for buttons, _ in COMBOS))
COOLDOWN = 5.0
SWITCH = os.environ["TV_SWITCH"]


class Hotkeys:
    def __init__(self):
        self.watched = set()
        self.ignored = set()
        self.last_switch = 0.0

    async def switch(self, seconds):
        await asyncio.sleep(seconds)
        now = asyncio.get_running_loop().time()
        if now - self.last_switch < COOLDOWN:
            return
        self.last_switch = now
        process = await asyncio.create_subprocess_exec(SWITCH, "toggle")
        await process.wait()

    async def watch(self, device):
        held = set()
        timers = {}
        try:
            async for event in device.async_read_loop():
                if event.type != ecodes.EV_KEY:
                    continue
                if event.value == 1:
                    held.add(event.code)
                elif event.value == 0:
                    held.discard(event.code)
                for index, (buttons, seconds) in enumerate(COMBOS):
                    if buttons <= held:
                        if index not in timers:
                            timers[index] = asyncio.create_task(self.switch(seconds))
                    elif index in timers:
                        timers.pop(index).cancel()
        except OSError:
            pass  # unplugged
        finally:
            for timer in timers.values():
                timer.cancel()
            self.watched.discard(device.path)
            device.close()

    async def run(self):
        while True:
            present = set(evdev.list_devices())
            self.ignored &= present
            for path in present - self.watched - self.ignored:
                try:
                    device = evdev.InputDevice(path)
                    keys = set(device.capabilities().get(ecodes.EV_KEY, []))
                except OSError:
                    continue
                if keys & WANTED:
                    self.watched.add(path)
                    asyncio.create_task(self.watch(device))
                else:
                    self.ignored.add(path)
                    device.close()
            await asyncio.sleep(3)


asyncio.run(Hotkeys().run())

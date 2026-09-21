"""The only module that speaks adb. Everything else goes through Adb."""
from __future__ import annotations

import subprocess
from dataclasses import dataclass

MARKER_DIR = "/sdcard/.lanbat-provision"


class AdbError(Exception):
    """adb reported a failure."""


class DeviceOffline(AdbError):
    """The device did not answer. Power it on, or check the address."""


class DeviceUnauthorized(AdbError):
    """The device answered but has not authorized this key.

    Accept the on-screen 'Allow USB debugging?' dialog once, with 'always allow'.
    """


@dataclass(frozen=True)
class DeviceInfo:
    sdk: int
    abis: list[str]
    model: str


class Adb:
    def __init__(self, host: str, port: int, adb_bin: str = "adb") -> None:
        self.host = host
        self.port = port
        self.adb_bin = adb_bin
        self.serial = f"{host}:{port}"

    def _run(self, args: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
        proc = subprocess.run(
            [self.adb_bin, *args], capture_output=True, text=True, timeout=300
        )
        if check and proc.returncode != 0:
            raise AdbError(f"adb {' '.join(args)} failed: {proc.stderr.strip() or proc.stdout.strip()}")
        return proc

    def connect(self) -> DeviceInfo:
        proc = self._run(["connect", self.serial], check=False)
        out = f"{proc.stdout} {proc.stderr}".lower()
        if "unauthorized" in out:
            raise DeviceUnauthorized(
                f"{self.serial} has not authorized this key; accept the on-screen "
                "'Allow USB debugging?' dialog with 'always allow'"
            )
        if proc.returncode != 0 or "failed to connect" in out or "cannot connect" in out:
            raise DeviceOffline(f"{self.serial} did not answer; is the box powered on?")

        # `adb connect` against an unauthorized device still reports success
        # above -- the unauthorized state only surfaces on the first real
        # command, as an AdbError from the shell calls below. Classify that
        # the same way as an unauthorized connect, instead of letting a bare
        # AdbError escape.
        try:
            sdk_raw = self.getprop("ro.build.version.sdk")
            abis = [a for a in self.getprop("ro.product.cpu.abilist").split(",") if a]
            model = self.getprop("ro.product.model")
        except AdbError as exc:
            message = str(exc).lower()
            if "unauthorized" in message:
                raise DeviceUnauthorized(
                    f"{self.serial} has not authorized this key; accept the on-screen "
                    "'Allow USB debugging?' dialog with 'always allow'"
                ) from exc
            raise DeviceOffline(
                f"{self.serial} stopped answering while reading device info: {exc}"
            ) from exc

        try:
            sdk = int(sdk_raw)
        except ValueError:
            raise DeviceOffline(
                f"{self.serial} returned an unparseable SDK version ({sdk_raw!r}) for "
                "ro.build.version.sdk; it may still be booting"
            ) from None

        return DeviceInfo(sdk=sdk, abis=abis, model=model)

    def getprop(self, name: str) -> str:
        return self.shell("getprop", name)

    def shell(self, *args: str) -> str:
        return self._run(["-s", self.serial, "shell", *args]).stdout.strip()

    def shell_ok(self, *args: str) -> bool:
        """Run a shell command for its exit status alone."""
        return self._run(["-s", self.serial, "shell", *args], check=False).returncode == 0

    def install(self, path: str, *, downgrade: bool = False) -> None:
        args = ["-s", self.serial, "install", "-r"]
        if downgrade:
            args.append("-d")
        args.append(path)
        self._run(args)

    def push(self, local: str, remote: str) -> None:
        self._run(["-s", self.serial, "push", local, remote])

    def marker_exists(self, rel: str) -> bool:
        return self.shell_ok("test", "-f", f"{MARKER_DIR}/{rel}")

    def write_marker(self, rel: str) -> None:
        path = f"{MARKER_DIR}/{rel}"
        parent = path.rsplit("/", 1)[0]
        self.shell("mkdir", "-p", parent)
        self.shell("touch", path)

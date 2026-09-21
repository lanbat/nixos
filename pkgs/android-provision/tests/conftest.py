import json
import os
import shutil
import sys
from pathlib import Path

import pytest

FAKE_ADB = Path(__file__).parent / "fake_adb.py"

BASE_STATE = {
    "connect": "ok",
    "props": {
        "ro.build.version.sdk": "34",
        "ro.product.cpu.abilist": "arm64-v8a,armeabi-v7a",
        "ro.product.model": "SEI804HM",
    },
    "packages": {},
    "settings": {"global": {}, "secure": {}, "system": {}},
    "files": [],
    "device_owner": None,
    "accounts": False,
    "readonly_settings": [],
    "apk_meta": {},
}


@pytest.fixture
def device(tmp_path, monkeypatch):
    """A fake device. Mutate device.state then call device.commit()."""

    class Device:
        def __init__(self):
            self.path = tmp_path / "state.json"
            self.state = json.loads(json.dumps(BASE_STATE))
            self.commit()
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            adb = bin_dir / "adb"
            shutil.copy(FAKE_ADB, adb)
            adb.chmod(0o755)
            monkeypatch.setenv("PATH", f"{bin_dir}:{os.environ['PATH']}")
            monkeypatch.setenv("FAKE_ADB_STATE", str(self.path))

        def commit(self):
            self.path.write_text(json.dumps(self.state))

        def reload(self):
            self.state = json.loads(self.path.read_text())
            return self.state

    return Device()

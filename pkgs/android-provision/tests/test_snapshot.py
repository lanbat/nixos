import json
import stat
from pathlib import Path

import pytest

from android_provision import snapshot
from android_provision.adb import Adb
from android_provision.cli import main

LOCKFILE = str(Path(__file__).parents[1] / "apks.lock.json")


def take(device):
    adb = Adb("192.0.2.50", 5555)
    return snapshot.take(adb, adb.connect(), device="bedroom")


def test_records_apps_with_version_and_installer(device):
    device.state["packages"] = {"com.nendo.argosy": 218, "com.netflix.ninja": 5}
    device.state["installers"] = {"com.netflix.ninja": "com.android.vending"}
    device.commit()
    snap = take(device)
    assert snap["packages"]["com.nendo.argosy"] == {"versionCode": 218, "installer": None}
    assert snap["packages"]["com.netflix.ninja"]["installer"] == "com.android.vending"


def test_records_settings_home_and_device_facts(device):
    device.state["settings"]["global"]["screen_off_timeout"] = "600000"
    device.commit()
    snap = take(device)
    assert snap["settings"]["global"] == {"screen_off_timeout": "600000"}
    assert snap["home"] == "com.google.android.tvlauncher/.MainActivity"
    assert snap["model"] == "SEI804HM" and snap["sdk"] == 34
    assert snap["schema"] == snapshot.SCHEMA


def test_value_with_equals_and_continuation_lines():
    text = "a=1\nb=x=y\nc=first\nsecond\nd=\n"
    assert snapshot.parse_settings(text) == {
        "a": "1", "b": "x=y", "c": "first\nsecond", "d": "",
    }


def test_capture_changes_nothing(device):
    before = json.loads(device.path.read_text())
    take(device)
    assert device.reload() == before


def test_save_is_private_and_load_round_trips(device, tmp_path):
    snap = take(device)
    path = snapshot.save(snap, str(tmp_path / "snaps"))
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert snapshot.load(str(path)) == snap


def test_load_rejects_other_schema(tmp_path):
    p = tmp_path / "s.json"
    p.write_text(json.dumps({"schema": 99}))
    with pytest.raises(snapshot.SnapshotError):
        snapshot.load(str(p))


def test_capture_cli_writes_a_snapshot(device, tmp_path):
    manifest = tmp_path / "m.json"
    manifest.write_text(json.dumps({
        "device": "bedroom", "host": "192.0.2.50", "port": 5555, "abi": "arm64-v8a",
    }))
    out = tmp_path / "snaps"
    assert main(["capture", "--manifest", str(manifest), "--out-dir", str(out),
                 "--lockfile", LOCKFILE, "--no-fdroid"]) == 0
    assert len(list(out.glob("*.json"))) == 1


def test_capture_cli_missing_lockfile_warns_but_still_succeeds(device, tmp_path, capsys):
    # The snapshot is already saved by the time the lockfile is read, so a
    # missing or unreadable lockfile (e.g. running from source without
    # --lockfile) must not fail the capture -- just skip the app report.
    manifest = tmp_path / "m.json"
    manifest.write_text(json.dumps({
        "device": "bedroom", "host": "192.0.2.50", "port": 5555, "abi": "arm64-v8a",
    }))
    out = tmp_path / "snaps"
    code = main(["capture", "--manifest", str(manifest), "--out-dir", str(out),
                 "--lockfile", str(tmp_path / "missing.lock.json"), "--no-fdroid"])
    assert code == 0
    assert len(list(out.glob("*.json"))) == 1
    err = capsys.readouterr().err
    assert "warning:" in err
    assert "Traceback" not in err


def test_capture_cli_malformed_lockfile_entry_warns_but_still_succeeds(device, tmp_path, capsys):
    # The snapshot is already saved by the time the app report runs; a
    # lockfile entry missing a required field (packageId) must not fail the
    # capture -- just skip the app-source report with a warning.
    device.state["packages"] = {"com.nendo.argosy": 218}
    device.commit()
    manifest = tmp_path / "m.json"
    manifest.write_text(json.dumps({
        "device": "bedroom", "host": "192.0.2.50", "port": 5555, "abi": "arm64-v8a",
    }))
    lockfile = tmp_path / "broken.lock.json"
    lockfile.write_text(json.dumps({
        "rommapp/argosy-launcher": {"source": "github", "variants": {}},
    }))
    out = tmp_path / "snaps"
    code = main(["capture", "--manifest", str(manifest), "--out-dir", str(out),
                 "--lockfile", str(lockfile), "--no-fdroid"])
    assert code == 0
    assert len(list(out.glob("*.json"))) == 1
    err = capsys.readouterr().err
    assert "warning:" in err
    assert "Traceback" not in err


def test_capture_cli_unauthorized_exits_3(device, tmp_path):
    device.state["connect"] = "unauthorized"
    device.commit()
    manifest = tmp_path / "m.json"
    manifest.write_text(json.dumps({
        "device": "bedroom", "host": "192.0.2.50", "port": 5555, "abi": "arm64-v8a",
    }))
    assert main(["capture", "--manifest", str(manifest), "--out-dir", str(tmp_path),
                 "--lockfile", LOCKFILE, "--no-fdroid"]) == 3


def test_capture_cli_device_drops_mid_capture_exits_2_without_traceback(device, tmp_path, capsys):
    # adb.connect() succeeds, but the box stops answering (Wi-Fi drop, reboot)
    # before the capture finishes. This must exit cleanly, not raise -- the
    # unit runs unattended.
    device.state["drops_after_connect"] = True
    device.commit()
    manifest = tmp_path / "m.json"
    manifest.write_text(json.dumps({
        "device": "bedroom", "host": "192.0.2.50", "port": 5555, "abi": "arm64-v8a",
    }))
    code = main(["capture", "--manifest", str(manifest), "--out-dir", str(tmp_path),
                 "--lockfile", LOCKFILE, "--no-fdroid"])
    assert code == 2
    err = capsys.readouterr().err
    assert "Traceback" not in err

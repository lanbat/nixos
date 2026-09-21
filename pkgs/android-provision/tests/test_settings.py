from android_provision.adb import Adb
from android_provision.manifest import DeviceOwner, Manifest
from android_provision.resources import settings as settings_resource


def make_manifest(table):
    return Manifest(
        device="bedroom", host="192.0.2.50", port=5555, abi="arm64-v8a",
        allowDowngrade=False, apks=[], caCerts=[], settings=table,
        obtainium=None, deviceOwner=DeviceOwner(False, None),
    )


def run(device, table, *, apply=True):
    adb = Adb("192.0.2.50", 5555)
    info = adb.connect()
    return settings_resource.reconcile(
        adb, info, make_manifest(table), apply=apply, force=False
    )


def test_missing_setting_is_written(device):
    outcomes = run(device, {"global": {"screen_off_timeout": "600000"}})
    assert [o.status for o in outcomes] == ["changed"]
    assert device.reload()["settings"]["global"]["screen_off_timeout"] == "600000"


def test_matching_setting_is_ok(device):
    device.state["settings"]["global"]["screen_off_timeout"] = "600000"
    device.commit()
    outcomes = run(device, {"global": {"screen_off_timeout": "600000"}})
    assert [o.status for o in outcomes] == ["ok"]


def test_protected_setting_that_silently_refuses_is_failed(device):
    device.state["readonly_settings"] = ["global/adb_enabled"]
    device.commit()
    outcomes = run(device, {"global": {"adb_enabled": "0"}})
    assert outcomes[0].status == "failed"
    assert "did not take" in outcomes[0].reason


def test_plan_mode_changes_nothing(device):
    outcomes = run(device, {"global": {"screen_off_timeout": "600000"}}, apply=False)
    assert outcomes[0].status == "changed"
    assert "screen_off_timeout" not in device.reload()["settings"]["global"]

from android_provision.adb import Adb
from android_provision.manifest import DeviceOwner, Manifest
from android_provision.resources import home


def make_manifest(activity):
    return Manifest(
        device="bedroom", host="192.0.2.50", port=5555, abi="arm64-v8a",
        allowDowngrade=False, apks=[], caCerts=[], settings={},
        obtainium=None, deviceOwner=DeviceOwner(False, None),
        homeActivity=activity,
    )


def run(device, activity, *, apply=True, force=False):
    adb = Adb("192.0.2.50", 5555)
    info = adb.connect()
    return home.reconcile(adb, info, make_manifest(activity), apply=apply, force=force)


def test_no_home_activity_configured_does_nothing(device):
    assert run(device, None) == []


def test_sets_home_when_different(device):
    outcomes = run(device, "com.nendo.argosy/.MainActivity")
    assert [o.status for o in outcomes] == ["changed"]
    assert device.reload()["home"] == "com.nendo.argosy/.MainActivity"


def test_matching_home_is_ok_in_short_or_full_form(device):
    device.state["home"] = "com.nendo.argosy/.MainActivity"
    device.commit()
    outcomes = run(device, "com.nendo.argosy/com.nendo.argosy.MainActivity")
    assert [o.status for o in outcomes] == ["ok"]


def test_refused_home_change_is_failed(device):
    device.state["home_locked"] = True
    device.commit()
    outcomes = run(device, "com.nendo.argosy/.MainActivity")
    assert outcomes[0].status == "failed"
    assert "tvlauncher" in outcomes[0].reason


def test_plan_mode_changes_nothing(device):
    outcomes = run(device, "com.nendo.argosy/.MainActivity", apply=False)
    assert outcomes[0].status == "changed"
    assert device.reload()["home"] == "com.google.android.tvlauncher/.MainActivity"


def test_no_home_resolved_reads_as_none(device):
    device.state["home"] = None
    device.commit()
    assert home.current_home(Adb("192.0.2.50", 5555)) is None

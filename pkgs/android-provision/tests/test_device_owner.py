from android_provision.adb import Adb
from android_provision.manifest import DeviceOwner, Manifest
from android_provision.resources import device_owner

COMPONENT = "com.example.dpc/.AdminReceiver"


def make_manifest(enable=True, component=COMPONENT):
    return Manifest(
        device="bedroom", host="192.0.2.50", port=5555, abi="arm64-v8a",
        allowDowngrade=False, apks=[], caCerts=[], settings={}, obtainium=None,
        deviceOwner=DeviceOwner(enable, component),
    )


def run(device, manifest=None, *, apply=True):
    adb = Adb("192.0.2.50", 5555)
    info = adb.connect()
    return device_owner.reconcile(
        adb, info, manifest or make_manifest(), apply=apply, force=False
    )


def test_disabled_yields_no_outcomes(device):
    assert run(device, make_manifest(enable=False, component=None)) == []


def test_unset_owner_is_set(device):
    outcomes = run(device)
    assert [o.status for o in outcomes] == ["changed"]
    assert device.reload()["device_owner"] == COMPONENT


def test_matching_owner_is_ok(device):
    device.state["device_owner"] = COMPONENT
    device.commit()
    assert [o.status for o in run(device)] == ["ok"]


def test_different_owner_is_failed(device):
    device.state["device_owner"] = "com.other/.Admin"
    device.commit()
    outcomes = run(device)
    assert outcomes[0].status == "failed"
    assert "already set" in outcomes[0].reason


def test_accounts_present_is_failed_with_reason(device):
    device.state["accounts"] = True
    device.commit()
    outcomes = run(device)
    assert outcomes[0].status == "failed"
    assert "factory reset" in outcomes[0].reason


def test_plan_mode_changes_nothing(device):
    outcomes = run(device, apply=False)
    assert outcomes[0].status == "changed"
    assert device.reload()["device_owner"] is None

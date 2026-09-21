from android_provision.adb import Adb
from android_provision.manifest import Apk, DeviceOwner, Manifest
from android_provision.resources import apks


def make_manifest(tmp_path, *entries, allow_downgrade=False):
    built = []
    for pkg, code, min_sdk in entries:
        path = tmp_path / f"{pkg}.apk"
        path.write_text("apk")
        built.append(
            Apk(packageId=pkg, versionCode=code, versionName=str(code),
                minSdk=min_sdk, path=str(path), source="fdroid")
        )
    return Manifest(
        device="bedroom", host="192.0.2.50", port=5555, abi="arm64-v8a",
        allowDowngrade=allow_downgrade, apks=built, caCerts=[], settings={},
        obtainium=None, deviceOwner=DeviceOwner(False, None),
    )


def run(device, tmp_path, *entries, allow_downgrade=False):
    for pkg, code, _ in entries:
        device.state["apk_meta"][f"{pkg}.apk"] = {"packageId": pkg, "versionCode": code}
    device.commit()
    adb = Adb("192.0.2.50", 5555)
    info = adb.connect()
    manifest = make_manifest(tmp_path, *entries, allow_downgrade=allow_downgrade)
    return adb, apks.reconcile(adb, info, manifest, apply=True, force=False)


def test_absent_package_is_installed(device, tmp_path):
    adb, outcomes = run(device, tmp_path, ("de.badaix.snapcast", 2902, 21))
    assert [o.status for o in outcomes] == ["changed"]
    assert device.reload()["packages"]["de.badaix.snapcast"] == 2902


def test_same_version_is_ok(device, tmp_path):
    device.state["packages"]["de.badaix.snapcast"] = 2902
    adb, outcomes = run(device, tmp_path, ("de.badaix.snapcast", 2902, 21))
    assert [o.status for o in outcomes] == ["ok"]


def test_older_installed_is_upgraded(device, tmp_path):
    device.state["packages"]["de.badaix.snapcast"] = 2700
    adb, outcomes = run(device, tmp_path, ("de.badaix.snapcast", 2902, 21))
    assert [o.status for o in outcomes] == ["changed"]
    assert device.reload()["packages"]["de.badaix.snapcast"] == 2902


def test_newer_installed_is_skipped_not_downgraded(device, tmp_path):
    device.state["packages"]["de.badaix.snapcast"] = 3000
    adb, outcomes = run(device, tmp_path, ("de.badaix.snapcast", 2902, 21))
    assert outcomes[0].status == "skipped"
    assert "newer installed" in outcomes[0].reason
    assert device.reload()["packages"]["de.badaix.snapcast"] == 3000


def test_newer_installed_is_downgraded_when_allowed(device, tmp_path):
    device.state["packages"]["de.badaix.snapcast"] = 3000
    adb, outcomes = run(device, tmp_path, ("de.badaix.snapcast", 2902, 21),
                        allow_downgrade=True)
    assert outcomes[0].status == "changed"
    assert device.reload()["packages"]["de.badaix.snapcast"] == 2902


def test_min_sdk_above_device_is_skipped(device, tmp_path):
    adb, outcomes = run(device, tmp_path, ("com.example.future", 1, 99))
    assert outcomes[0].status == "skipped"
    assert "minSdk 99 > device 34" in outcomes[0].reason
    assert "com.example.future" not in device.reload()["packages"]


def test_plan_mode_changes_nothing(device, tmp_path):
    device.state["apk_meta"]["de.badaix.snapcast.apk"] = {
        "packageId": "de.badaix.snapcast", "versionCode": 2902}
    device.commit()
    adb = Adb("192.0.2.50", 5555)
    info = adb.connect()
    manifest = make_manifest(tmp_path, ("de.badaix.snapcast", 2902, 21))
    outcomes = apks.reconcile(adb, info, manifest, apply=False, force=False)
    assert outcomes[0].status == "changed"
    assert "de.badaix.snapcast" not in device.reload()["packages"]

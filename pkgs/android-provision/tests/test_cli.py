import json

from android_provision import cli


def write_manifest(tmp_path, **overrides):
    apk = tmp_path / "snap.apk"
    apk.write_text("apk")
    data = {
        "device": "bedroom", "host": "192.0.2.50", "port": 5555, "abi": "arm64-v8a",
        "allowDowngrade": False,
        "apks": [{"packageId": "de.badaix.snapcast", "versionCode": 2902,
                  "versionName": "0.29.0.2", "minSdk": 21, "path": str(apk),
                  "source": "fdroid"}],
        "caCerts": [], "settings": {"global": {"screen_off_timeout": "600000"}},
        "obtainium": None, "deviceOwner": {"enable": False, "component": None},
    }
    data.update(overrides)
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(data))
    return str(path)


def prime(device):
    device.state["apk_meta"]["snap.apk"] = {
        "packageId": "de.badaix.snapcast", "versionCode": 2902}
    device.commit()


def test_provision_converges_and_exits_zero(device, tmp_path, capsys):
    prime(device)
    assert cli.main(["provision", "--manifest", write_manifest(tmp_path)]) == 0
    state = device.reload()
    assert state["packages"]["de.badaix.snapcast"] == 2902
    assert state["settings"]["global"]["screen_off_timeout"] == "600000"


def test_second_run_is_all_ok(device, tmp_path, capsys):
    prime(device)
    manifest = write_manifest(tmp_path)
    cli.main(["provision", "--manifest", manifest])
    capsys.readouterr()
    assert cli.main(["provision", "--manifest", manifest]) == 0
    out = capsys.readouterr().out
    assert "changed" not in out
    assert "ok" in out


def test_plan_changes_nothing(device, tmp_path):
    prime(device)
    assert cli.main(["plan", "--manifest", write_manifest(tmp_path)]) == 0
    assert "de.badaix.snapcast" not in device.reload()["packages"]


def test_offline_exits_2(device, tmp_path):
    device.state["connect"] = "offline"
    device.commit()
    assert cli.main(["provision", "--manifest", write_manifest(tmp_path)]) == 2


def test_unauthorized_exits_3(device, tmp_path):
    # Real adb: connect succeeds; unauthorized only surfaces on the first
    # command issued after it (getprop, inside adb.connect()). This is the
    # first thing a user following "One-time ADB authorization" hits.
    device.state["connect"] = "unauthorized"
    device.commit()
    assert cli.main(["provision", "--manifest", write_manifest(tmp_path)]) == 3


def test_junk_sdk_exits_2_without_traceback(device, tmp_path, capsys):
    # connect() succeeds, but the device answers getprop with garbage: must
    # be EXIT_UNREACHABLE with a clear message, never an unhandled traceback.
    device.state["props"]["ro.build.version.sdk"] = "unknown"
    device.commit()
    code = cli.main(["provision", "--manifest", write_manifest(tmp_path)])
    assert code == 2
    err = capsys.readouterr().err
    assert "Traceback" not in err


def test_bad_manifest_exits_4(device, tmp_path):
    path = tmp_path / "broken.json"
    path.write_text("{not json")
    assert cli.main(["provision", "--manifest", str(path)]) == 4


def test_one_failure_does_not_stop_the_rest(device, tmp_path, capsys):
    prime(device)
    device.state["readonly_settings"] = ["global/screen_off_timeout"]
    device.commit()
    code = cli.main(["provision", "--manifest", write_manifest(tmp_path)])
    assert code == 1
    assert device.reload()["packages"]["de.badaix.snapcast"] == 2902

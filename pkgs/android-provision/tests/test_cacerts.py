from android_provision.adb import Adb
from android_provision.manifest import CaCert, DeviceOwner, Manifest
from android_provision.resources import cacerts


def make_manifest(tmp_path, sha="abc123", name="caddy-ca-root"):
    cert = tmp_path / "root.crt"
    cert.write_text("-----BEGIN CERTIFICATE-----\n")
    return Manifest(
        device="bedroom", host="192.0.2.50", port=5555, abi="arm64-v8a",
        allowDowngrade=False, apks=[],
        caCerts=[CaCert(name=name, sha256=sha, path=str(cert))],
        settings={}, obtainium=None, deviceOwner=DeviceOwner(False, None),
    )


def android_10(device):
    """The install dialog path: Android 10 (SDK 29) still opens it from adb."""
    device.state["props"]["ro.build.version.sdk"] = "29"
    device.commit()


def run(device, tmp_path, *, apply=True, force=False, sha="abc123", name="caddy-ca-root"):
    adb = Adb("192.0.2.50", 5555)
    info = adb.connect()
    return adb, cacerts.reconcile(
        adb, info, make_manifest(tmp_path, sha=sha, name=name), apply=apply, force=force
    )


def test_absent_marker_pushes_cert_and_reports_manual_step(device, tmp_path):
    android_10(device)
    adb, outcomes = run(device, tmp_path)
    assert outcomes[0].status == "changed"
    assert "on-screen" in outcomes[0].reason
    assert adb.marker_exists("cacerts/abc123") is True
    # Verify the intent was launched with correct action and mime type
    intents = device.reload()["intents"]
    assert len(intents) == 1
    intent = intents[0]
    assert "-a" in intent
    assert "android.credentials.INSTALL" in intent
    assert "-t" in intent
    assert "application/x-x509-ca-cert" in intent


def test_existing_marker_is_ok(device, tmp_path):
    android_10(device)
    adb = Adb("192.0.2.50", 5555)
    adb.connect()
    adb.write_marker("cacerts/abc123")
    _, outcomes = run(device, tmp_path)
    assert [o.status for o in outcomes] == ["ok"]


def test_force_reapplies_despite_marker(device, tmp_path):
    android_10(device)
    adb = Adb("192.0.2.50", 5555)
    adb.connect()
    adb.write_marker("cacerts/abc123")
    _, outcomes = run(device, tmp_path, force=True)
    assert outcomes[0].status == "changed"


def test_plan_mode_writes_no_marker(device, tmp_path):
    android_10(device)
    adb, outcomes = run(device, tmp_path, apply=False)
    assert outcomes[0].status == "changed"
    assert adb.marker_exists("cacerts/abc123") is False


def test_unresolved_install_intent_is_failed_and_writes_no_marker(device, tmp_path):
    android_10(device)
    # Real `am start`: when nothing resolves the intent, it prints an
    # "Error:" line on stdout and still exits 0. This is the one resource
    # whose real state can't be read back, so a failed install must never
    # self-certify by writing the marker.
    device.state["am_start_fails"] = True
    device.commit()
    adb, outcomes = run(device, tmp_path)
    assert outcomes[0].status == "failed"
    assert adb.marker_exists("cacerts/abc123") is False


def test_extension_not_doubled_when_name_already_has_it(device, tmp_path):
    android_10(device)
    # The Nix side sets `name` to baseNameOf the cert path, which already
    # includes ".crt" (e.g. "caddy-ca-root.crt"). The remote filename must
    # end up "caddy-ca-root.crt", never "caddy-ca-root.crt.crt".
    _, outcomes = run(device, tmp_path, name="caddy-ca-root.crt")
    assert outcomes[0].status == "changed"
    intents = device.reload()["intents"]
    intent = intents[0]
    d_value = intent[intent.index("-d") + 1]
    assert d_value == "file:///sdcard/Download/caddy-ca-root.crt"


def test_name_with_space_reaches_the_device_as_one_token(device, tmp_path):
    android_10(device)
    # adb joins its trailing shell arguments with spaces before sending them
    # to the device's own shell, which re-splits on whitespace. Without
    # quoting, a cert name containing a space breaks the remote `am start`
    # command into extra words instead of surviving as one path.
    _, outcomes = run(device, tmp_path, name="My Cert")
    assert outcomes[0].status == "changed"
    intents = device.reload()["intents"]
    intent = intents[0]
    d_value = intent[intent.index("-d") + 1]
    assert d_value == "file:///sdcard/Download/My Cert.crt"


# Android 11 (SDK 30) and later refuse to open the CA install dialog from adb
# (the reference box logs START result -91 and shows nothing), and Android TV's
# Settings may have no certificate screen at all. So the provisioner delivers
# the file, launches nothing, and never claims the CA is installed.


def test_android_11_plus_delivers_the_file_and_launches_nothing(device, tmp_path):
    adb, outcomes = run(device, tmp_path)
    assert outcomes[0].status == "changed"
    assert "/sdcard/Download/caddy-ca-root.crt" in outcomes[0].reason
    assert "Settings" in outcomes[0].reason and "import" in outcomes[0].reason
    state = device.reload()
    assert state.get("intents", []) == []
    assert "/sdcard/Download/caddy-ca-root.crt" in state["files"]
    assert adb.marker_exists("cacerts/abc123") is False


def test_android_11_plus_file_already_delivered_is_ok(device, tmp_path):
    device.state["files"] = ["/sdcard/Download/caddy-ca-root.crt"]
    device.commit()
    _, outcomes = run(device, tmp_path)
    assert outcomes[0].status == "ok"
    assert "/sdcard/Download/caddy-ca-root.crt" in outcomes[0].reason


def test_android_11_plus_plan_mode_pushes_nothing(device, tmp_path):
    _, outcomes = run(device, tmp_path, apply=False)
    assert outcomes[0].status == "changed"
    assert "/sdcard/Download/caddy-ca-root.crt" in outcomes[0].reason
    assert device.reload().get("files", []) == []


def test_android_11_plus_force_pushes_again(device, tmp_path):
    device.state["files"] = ["/sdcard/Download/caddy-ca-root.crt"]
    device.commit()
    _, outcomes = run(device, tmp_path, force=True)
    assert outcomes[0].status == "changed"
    assert device.reload()["files"].count("/sdcard/Download/caddy-ca-root.crt") == 2

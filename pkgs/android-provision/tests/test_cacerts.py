from android_provision.adb import Adb
from android_provision.manifest import CaCert, DeviceOwner, Manifest
from android_provision.resources import cacerts


def make_manifest(tmp_path, sha="abc123"):
    cert = tmp_path / "root.crt"
    cert.write_text("-----BEGIN CERTIFICATE-----\n")
    return Manifest(
        device="bedroom", host="192.0.2.50", port=5555, abi="arm64-v8a",
        allowDowngrade=False, apks=[],
        caCerts=[CaCert(name="caddy-ca-root", sha256=sha, path=str(cert))],
        settings={}, obtainium=None, deviceOwner=DeviceOwner(False, None),
    )


def run(device, tmp_path, *, apply=True, force=False):
    adb = Adb("192.0.2.50", 5555)
    info = adb.connect()
    return adb, cacerts.reconcile(
        adb, info, make_manifest(tmp_path), apply=apply, force=force
    )


def test_absent_marker_pushes_cert_and_reports_manual_step(device, tmp_path):
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
    adb = Adb("192.0.2.50", 5555)
    adb.connect()
    adb.write_marker("cacerts/abc123")
    _, outcomes = run(device, tmp_path)
    assert [o.status for o in outcomes] == ["ok"]


def test_force_reapplies_despite_marker(device, tmp_path):
    adb = Adb("192.0.2.50", 5555)
    adb.connect()
    adb.write_marker("cacerts/abc123")
    _, outcomes = run(device, tmp_path, force=True)
    assert outcomes[0].status == "changed"


def test_plan_mode_writes_no_marker(device, tmp_path):
    adb, outcomes = run(device, tmp_path, apply=False)
    assert outcomes[0].status == "changed"
    assert adb.marker_exists("cacerts/abc123") is False


def test_unresolved_install_intent_is_failed_and_writes_no_marker(device, tmp_path):
    # Real `am start`: when nothing resolves the intent, it prints an
    # "Error:" line on stdout and still exits 0. This is the one resource
    # whose real state can't be read back, so a failed install must never
    # self-certify by writing the marker.
    device.state["am_start_fails"] = True
    device.commit()
    adb, outcomes = run(device, tmp_path)
    assert outcomes[0].status == "failed"
    assert adb.marker_exists("cacerts/abc123") is False

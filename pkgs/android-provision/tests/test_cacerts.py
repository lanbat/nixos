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

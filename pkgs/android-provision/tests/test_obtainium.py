from android_provision.adb import Adb
from android_provision.manifest import DeviceOwner, Manifest, Obtainium
from android_provision.resources import obtainium as obtainium_resource

URLS = "\n".join([
    "https://github.com/theothernt/AerialViews",
    "https://github.com/ImranR98/Obtainium",
]) + "\n"


def make_manifest(tmp_path, sha="def456"):
    listing = tmp_path / "obtainium-urls.txt"
    listing.write_text(URLS)
    return Manifest(
        device="bedroom", host="192.0.2.50", port=5555, abi="arm64-v8a",
        allowDowngrade=False, apks=[], caCerts=[], settings={},
        obtainium=Obtainium(path=str(listing), sha256=sha),
        deviceOwner=DeviceOwner(False, None),
    )


def run(device, tmp_path, *, apply=True, force=False):
    adb = Adb("192.0.2.50", 5555)
    info = adb.connect()
    return adb, obtainium_resource.reconcile(
        adb, info, make_manifest(tmp_path), apply=apply, force=force
    )


def test_absent_marker_pushes_list(device, tmp_path):
    adb, outcomes = run(device, tmp_path)
    assert outcomes[0].status == "changed"
    assert "Import from URL list" in outcomes[0].reason
    assert adb.marker_exists("obtainium/def456") is True


def test_existing_marker_is_ok(device, tmp_path):
    adb = Adb("192.0.2.50", 5555)
    adb.connect()
    adb.write_marker("obtainium/def456")
    _, outcomes = run(device, tmp_path)
    assert [o.status for o in outcomes] == ["ok"]


def test_no_obtainium_section_yields_no_outcomes(device, tmp_path):
    adb = Adb("192.0.2.50", 5555)
    info = adb.connect()
    manifest = make_manifest(tmp_path)
    manifest = Manifest(**{**manifest.__dict__, "obtainium": None})
    assert obtainium_resource.reconcile(adb, info, manifest, apply=True, force=False) == []


def test_plan_mode_writes_no_marker(device, tmp_path):
    adb, outcomes = run(device, tmp_path, apply=False)
    assert outcomes[0].status == "changed"
    assert adb.marker_exists("obtainium/def456") is False

import json

import pytest

from android_provision.manifest import ManifestError, load


def write(tmp_path, data):
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(data))
    return str(path)


MINIMAL = {
    "device": "bedroom",
    "host": "192.0.2.50",
    "port": 5555,
    "abi": "arm64-v8a",
    "allowDowngrade": False,
    "apks": [],
    "caCerts": [],
    "settings": {},
    "obtainium": None,
    "deviceOwner": {"enable": False, "component": None},
}


def test_load_minimal(tmp_path):
    m = load(write(tmp_path, MINIMAL))
    assert m.device == "bedroom"
    assert m.port == 5555
    assert m.apks == []
    assert m.deviceOwner.enable is False


def test_load_coerces_setting_values_to_strings(tmp_path):
    data = dict(MINIMAL, settings={"global": {"screen_off_timeout": 600000}})
    m = load(write(tmp_path, data))
    assert m.settings["global"]["screen_off_timeout"] == "600000"


def test_load_rejects_unknown_settings_namespace(tmp_path):
    data = dict(MINIMAL, settings={"bogus": {"a": "b"}})
    with pytest.raises(ManifestError, match="namespace"):
        load(write(tmp_path, data))


def test_load_rejects_device_owner_without_component(tmp_path):
    data = dict(MINIMAL, deviceOwner={"enable": True, "component": None})
    with pytest.raises(ManifestError, match="component"):
        load(write(tmp_path, data))


def test_load_rejects_obtainium_missing_sha256(tmp_path):
    data = dict(MINIMAL, obtainium={"path": "/x"})
    with pytest.raises(ManifestError):
        load(write(tmp_path, data))


def test_load_rejects_settings_wrong_type(tmp_path):
    data = dict(MINIMAL, settings="nonsense")
    with pytest.raises(ManifestError):
        load(write(tmp_path, data))


def test_load_rejects_device_owner_wrong_type(tmp_path):
    data = dict(MINIMAL, deviceOwner="yes")
    with pytest.raises(ManifestError):
        load(write(tmp_path, data))


def test_load_rejects_port_non_numeric(tmp_path):
    data = dict(MINIMAL, port="abc")
    with pytest.raises(ManifestError):
        load(write(tmp_path, data))

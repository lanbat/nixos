import pytest

from android_provision.adb import Adb, DeviceOffline, DeviceUnauthorized


def test_connect_reads_device_info(device):
    device.state["props"]["ro.product.model"] = "SEI804HM"
    device.commit()

    info = Adb("192.0.2.50", 5555).connect()

    assert info.sdk == 34
    assert info.abis == ["arm64-v8a", "armeabi-v7a"]
    assert info.model == "SEI804HM"


def test_connect_offline_raises(device):
    device.state["connect"] = "offline"
    device.commit()

    with pytest.raises(DeviceOffline):
        Adb("192.0.2.50", 5555).connect()


def test_connect_unauthorized_raises(device):
    device.state["connect"] = "unauthorized"
    device.commit()

    with pytest.raises(DeviceUnauthorized):
        Adb("192.0.2.50", 5555).connect()


def test_marker_roundtrip(device):
    adb = Adb("192.0.2.50", 5555)
    adb.connect()

    assert adb.marker_exists("cacerts/abc123") is False
    adb.write_marker("cacerts/abc123")
    assert adb.marker_exists("cacerts/abc123") is True

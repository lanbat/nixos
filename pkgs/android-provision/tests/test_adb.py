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
    # Real adb: `connect` against an unauthorized device succeeds and exits
    # 0; unauthorized only surfaces on the first real command (getprop, here
    # inside connect() itself). This proves that surfacing still ends up as
    # DeviceUnauthorized, not a bare AdbError.
    device.state["connect"] = "unauthorized"
    device.commit()

    with pytest.raises(DeviceUnauthorized):
        Adb("192.0.2.50", 5555).connect()


def test_connect_with_junk_sdk_raises_offline(device):
    # A box that answers `connect` but returns an unparseable
    # ro.build.version.sdk (mid-boot, wrong device, adb talking nonsense)
    # must not raise a bare ValueError out of connect().
    device.state["props"]["ro.build.version.sdk"] = ""
    device.commit()

    with pytest.raises(DeviceOffline):
        Adb("192.0.2.50", 5555).connect()


def test_marker_roundtrip(device):
    adb = Adb("192.0.2.50", 5555)
    adb.connect()

    assert adb.marker_exists("cacerts/abc123") is False
    adb.write_marker("cacerts/abc123")
    assert adb.marker_exists("cacerts/abc123") is True

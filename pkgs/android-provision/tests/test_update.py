import json
from pathlib import Path

import pytest

from android_provision import update

FIXTURES = Path(__file__).parent / "fixtures"


def index():
    return json.loads((FIXTURES / "fdroid-index-v2.json").read_text())


def release():
    return json.loads((FIXTURES / "github-release.json").read_text())


def test_fdroid_takes_highest_version_code():
    entry = update.resolve_fdroid(index(), "de.badaix.snapcast")
    assert entry["versionCode"] == 2902
    assert entry["versionName"] == "0.29.0.2"
    assert entry["minSdk"] == 21
    assert entry["source"] == "fdroid"


def test_fdroid_records_every_abi_variant():
    entry = update.resolve_fdroid(index(), "org.videolan.vlc")
    assert set(entry["variants"]) == {"arm64-v8a", "armeabi-v7a"}
    assert entry["variants"]["arm64-v8a"]["url"].endswith("/org.videolan.vlc_13060535.apk")
    assert entry["variants"]["arm64-v8a"]["sha256"].startswith("sha256-")


def test_fdroid_app_without_nativecode_is_universal():
    entry = update.resolve_fdroid(index(), "de.badaix.snapcast")
    assert list(entry["variants"]) == ["universal"]


def test_fdroid_unknown_package_raises():
    with pytest.raises(update.ResolveError, match="not on F-Droid"):
        update.resolve_fdroid(index(), "com.example.missing")


def test_fdroid_highest_version_code_wins_a_shared_abi_slot():
    # Two versions share versionName "1.0.0" and the same ABI (arm64-v8a), as
    # happens with a hotfix repackage that bumps versionCode but not
    # versionName. The pinned APK for that ABI must come from the higher
    # versionCode entry (101), matching the versionCode recorded on the
    # resolved entry -- not whichever entry happened to be iterated last.
    fixture = {
        "packages": {
            "com.example.hotfix": {
                "metadata": {"preferredSigner": "abc"},
                # Declared with the higher versionCode FIRST: dict (and hence
                # `.values()`) iteration order matches declaration order, so an
                # implementation that iterates `chosen` unsorted would let the
                # lower versionCode (100) overwrite the higher one (101) in the
                # variants map -- this ordering is what makes the test catch
                # that bug instead of passing by coincidence.
                "versions": {
                    "v101": {
                        "added": 2000,
                        "file": {"name": "/com.example.hotfix_101.apk",
                                 "sha256": "bb" * 34, "size": 1001},
                        "manifest": {"versionName": "1.0.0", "versionCode": 101,
                                     "usesSdk": {"minSdkVersion": 21},
                                     "nativecode": ["arm64-v8a"]},
                    },
                    "v100": {
                        "added": 1000,
                        "file": {"name": "/com.example.hotfix_100.apk",
                                 "sha256": "aa" * 34, "size": 1000},
                        "manifest": {"versionName": "1.0.0", "versionCode": 100,
                                     "usesSdk": {"minSdkVersion": 21},
                                     "nativecode": ["arm64-v8a"]},
                    },
                },
            }
        }
    }
    entry = update.resolve_fdroid(fixture, "com.example.hotfix")
    assert entry["versionCode"] == 101
    assert entry["variants"]["arm64-v8a"]["url"].endswith("/com.example.hotfix_101.apk")


def test_github_glob_picks_the_matching_asset():
    asset = update.select_asset(release(), "*-github.apk")
    assert asset["name"] == "AerialViews-1.9.1-github.apk"


def test_github_ambiguous_glob_raises():
    with pytest.raises(update.ResolveError, match="matched 2 assets"):
        update.select_asset(release(), "*.apk")


def test_github_glob_matching_nothing_raises():
    with pytest.raises(update.ResolveError, match="matched no assets"):
        update.select_asset(release(), "*.aab")


def test_write_lockfile_is_sorted_and_stable(tmp_path):
    path = tmp_path / "apks.lock.json"
    update.write_lockfile(str(path), [
        {"source": "fdroid", "key": "z.app"},
        {"source": "fdroid", "key": "a.app"},
    ])
    data = json.loads(path.read_text())
    assert list(data) == ["a.app", "z.app"]
    first = path.read_text()
    update.write_lockfile(str(path), [
        {"source": "fdroid", "key": "a.app"},
        {"source": "fdroid", "key": "z.app"},
    ])
    assert path.read_text() == first

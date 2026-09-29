from android_provision import sources

LOCK = {
    "de.badaix.snapcast": {"source": "fdroid", "packageId": "de.badaix.snapcast",
                           "variants": {"arm64-v8a": {"url": "https://f-droid.org/repo/x.apk"}}},
    "rommapp/argosy-launcher": {"source": "github", "packageId": "com.nendo.argosy",
                                "variants": {"arm64-v8a": {"url": "https://github.com/rommapp/argosy-launcher/releases/download/v2.18.0/argosy-v2.18.0-arm64.apk"}}},
}
PKGS = {
    "de.badaix.snapcast": {"versionCode": 1, "installer": None},
    "com.nendo.argosy": {"versionCode": 1, "installer": None},
    "org.fdroid.only": {"versionCode": 1, "installer": "org.fdroid.fdroid"},
    "com.netflix.ninja": {"versionCode": 1, "installer": "com.android.vending"},
    "com.mystery": {"versionCode": 1, "installer": None},
}


def kinds(fdroid):
    return {p.packageId: p.kind for p in sources.propose(PKGS, LOCK, fdroid)}


def test_each_app_gets_a_source():
    assert kinds({"packages": {"org.fdroid.only": {}}}) == {
        "de.badaix.snapcast": "lockfile-fdroid",
        "com.nendo.argosy": "lockfile-github",
        "org.fdroid.only": "fdroid",
        "com.netflix.ninja": "play",
        "com.mystery": "unknown",
    }


def test_without_fdroid_index_unlocked_apps_are_unknown():
    assert kinds(None)["org.fdroid.only"] == "unknown"


def test_fragment_is_pasteable():
    frag = sources.fragment(sources.propose(PKGS, LOCK, {"packages": {"org.fdroid.only": {}}}))
    assert 'packages = [ "de.badaix.snapcast" "org.fdroid.only" ];' in frag
    assert '{ repo = "rommapp/argosy-launcher"; asset = "argosy-v2.18.0-arm64.apk"; }' in frag
    assert "# Play Store: com.netflix.ninja" in frag
    assert "# no known source: com.mystery" in frag

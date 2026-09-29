from pathlib import Path

from android_provision import diff

LOCKFILE = str(Path(__file__).parents[1] / "apks.lock.json")


def snap(settings=None, packages=None, home="com.google.android.tvlauncher/.MainActivity"):
    base = {"global": {}, "secure": {}, "system": {}}
    for ns, table in (settings or {}).items():
        base[ns] = table
    return {"schema": 1, "settings": base, "packages": packages or {}, "home": home}


def test_changed_and_removed_settings_become_restore_values():
    old = snap({"global": {"screen_off_timeout": "600000", "animator_duration_scale": "0.5"}})
    new = snap({"global": {"screen_off_timeout": "300000"}})
    d = diff.compare(old, new)
    frag = diff.restore_fragment(d)
    assert '"screen_off_timeout" = "600000";' in frag
    assert '"animator_duration_scale" = "0.5";' in frag


def test_key_only_on_new_box_is_listed_not_restored():
    d = diff.compare(snap(), snap({"secure": {"new_key": "1"}}))
    assert [(c.ns, c.key, c.old, c.new) for c in d.settings] == [("secure", "new_key", None, "1")]
    assert not any(
        "new_key" in line
        for line in diff.restore_fragment(d).splitlines()
        if not line.lstrip().startswith("#")
    )
    assert "new_key" in diff.render(d)


def test_volatile_and_ignored_keys_are_skipped():
    old = snap({"global": {"boot_count": "3", "mine": "a"}})
    new = snap({"global": {"boot_count": "1", "mine": "b"}})
    assert diff.compare(old, new, ignore=frozenset({"global/mine"})).settings == []


def test_apps_and_home_differences():
    old = snap(packages={"com.nendo.argosy": {"versionCode": 218, "installer": None}},
               home="com.nendo.argosy/.MainActivity")
    new = snap(packages={"org.example": {"versionCode": 1, "installer": None}})
    d = diff.compare(old, new)
    assert d.apps_missing == ["com.nendo.argosy"]
    assert d.apps_added == ["org.example"]
    assert d.home == ("com.nendo.argosy/.MainActivity", "com.google.android.tvlauncher/.MainActivity")
    assert 'homeActivity = "com.nendo.argosy/.MainActivity";' in diff.restore_fragment(d)


def test_same_home_in_short_and_full_form_is_no_difference():
    d = diff.compare(snap(home="a.b/.Main"), snap(home="a.b/a.b.Main"))
    assert d.home is None


def test_nix_escaping():
    d = diff.compare(snap({"system": {"name": 'say "hi" \\ ${x}'}}), snap())
    assert '"name" = "say \\"hi\\" \\\\ \\${x}";' in diff.restore_fragment(d)


def test_diff_cli(tmp_path, capsys):
    import json
    from android_provision.cli import main
    a, b = tmp_path / "a.json", tmp_path / "b.json"
    a.write_text(json.dumps(snap({"global": {"k": "1"}})))
    b.write_text(json.dumps(snap({"global": {"k": "2"}})))
    assert main(["diff", str(a), str(b)]) == 0
    assert '"k" = "1";' in capsys.readouterr().out


def test_capture_cli_diff_prints_restore_fragment(device, tmp_path, capsys):
    device.state["settings"]["global"]["screen_off_timeout"] = "300000"
    device.commit()
    import json
    from android_provision.cli import main
    old = tmp_path / "old.json"
    old.write_text(json.dumps(snap({"global": {"screen_off_timeout": "600000"}})))
    manifest = tmp_path / "m.json"
    manifest.write_text(json.dumps({
        "device": "bedroom", "host": "192.0.2.50", "port": 5555, "abi": "arm64-v8a",
    }))
    out = tmp_path / "snaps"
    code = main(["capture", "--manifest", str(manifest), "--out-dir", str(out),
                 "--lockfile", LOCKFILE, "--no-fdroid", "--diff", str(old)])
    assert code == 0
    assert '"screen_off_timeout" = "600000";' in capsys.readouterr().out


def test_capture_cli_diff_missing_old_snapshot_exits_manifest_but_keeps_new_snapshot(device, tmp_path):
    import json
    from android_provision.cli import EXIT_MANIFEST, main
    manifest = tmp_path / "m.json"
    manifest.write_text(json.dumps({
        "device": "bedroom", "host": "192.0.2.50", "port": 5555, "abi": "arm64-v8a",
    }))
    out = tmp_path / "snaps"
    code = main(["capture", "--manifest", str(manifest), "--out-dir", str(out),
                 "--lockfile", LOCKFILE, "--no-fdroid", "--diff", str(tmp_path / "missing.json")])
    assert code == EXIT_MANIFEST
    assert len(list(out.glob("*.json"))) == 1

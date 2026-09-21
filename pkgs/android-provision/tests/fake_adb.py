#!/usr/bin/env python3
"""An adb stand-in for tests, backed by the JSON file named by $FAKE_ADB_STATE."""
import json
import os
import sys

STATE = os.environ["FAKE_ADB_STATE"]


def load():
    with open(STATE) as fh:
        return json.load(fh)


def save(state):
    with open(STATE, "w") as fh:
        json.dump(state, fh)


def main(argv):
    state = load()
    if argv[0] == "connect":
        status = state.get("connect", "ok")
        if status == "offline":
            print(f"failed to connect to {argv[1]}")
            return 1
        # Real adb: `connect` against an unauthorized device still prints
        # "connected to <serial>" and exits 0. The unauthorized state only
        # surfaces on the *next* command (see below) -- it is not visible at
        # connect time.
        print(f"connected to {argv[1]}")
        return 0

    # every remaining form is: -s <serial> <verb> ...
    verb, rest = argv[2], argv[3:]

    if state.get("connect") == "unauthorized":
        print(
            "error: device unauthorized.\n"
            "This adb server's $ADB_VENDOR_KEYS is not set\n"
            "Try 'adb kill-server' if that seems wrong.\n"
            "Otherwise check for a confirmation dialog on your device.",
            file=sys.stderr,
        )
        return 1

    if verb == "shell":
        return shell(state, rest)
    if verb == "install":
        return install(state, rest)
    if verb == "push":
        state.setdefault("files", []).append(rest[1])
        save(state)
        print("1 file pushed")
        return 0
    print(f"unknown verb {verb}", file=sys.stderr)
    return 2


def shell(state, args):
    if args[0] == "getprop":
        print(state["props"].get(args[1], ""))
        return 0
    if args[0] == "settings":
        return settings(state, args[1:])
    if args[0] == "pm" and args[1] == "list" and args[2] == "packages":
        for pkg in sorted(state["packages"]):
            print(f"package:{pkg}")
        return 0
    if args[0] == "dumpsys" and args[1] == "package":
        code = state["packages"].get(args[2])
        if code is None:
            return 0
        print(f"    versionCode={code} minSdk=21 targetSdk=34")
        return 0
    if args[0] == "dumpsys" and args[1] == "device_policy":
        owner = state.get("device_owner")
        print(f"Device Owner: {owner}" if owner else "Device Owner: null")
        return 0
    if args[0] == "dpm" and args[1] == "set-device-owner":
        if state.get("accounts"):
            print("java.lang.IllegalStateException: Not allowed to set the device owner"
                  " because there are already some accounts on the device", file=sys.stderr)
            return 1
        if state.get("device_owner"):
            print("java.lang.IllegalStateException: Trying to set the device owner"
                  " but device owner is already set.", file=sys.stderr)
            return 1
        state["device_owner"] = args[2]
        save(state)
        print(f"Success: Device owner set to package {args[2]}")
        return 0
    if args[0] == "am" and args[1] == "start":
        if state.get("am_start_fails"):
            # Real am: when nothing resolves the intent, this prints an
            # "Error:" line on stdout and *still exits 0*.
            print(f"Error: Activity not started, unable to resolve Intent {{ {' '.join(args[2:])} }}")
            return 0
        state.setdefault("intents", []).append(args[2:])
        save(state)
        print("Starting: Intent { ... }")
        return 0
    if args[0] == "test":
        # test -f <path>
        return 0 if args[2] in state.get("files", []) else 1
    if args[0] == "mkdir":
        return 0
    if args[0] == "touch":
        state.setdefault("files", []).append(args[1])
        save(state)
        return 0
    print(f"unknown shell command {args}", file=sys.stderr)
    return 2


def settings(state, args):
    verb, ns, key = args[0], args[1], args[2]
    table = state.setdefault("settings", {}).setdefault(ns, {})
    if verb == "get":
        print(table.get(key, "null"))
        return 0
    if verb == "put":
        if f"{ns}/{key}" not in state.get("readonly_settings", []):
            table[key] = args[3]
            save(state)
        return 0
    return 2


def install(state, args):
    path = args[-1]
    meta = state["apk_meta"][os.path.basename(path)]
    installed = state["packages"].get(meta["packageId"])
    if installed is not None and installed > meta["versionCode"] and "-d" not in args:
        print("adb: failed to install: INSTALL_FAILED_VERSION_DOWNGRADE", file=sys.stderr)
        return 1
    state["packages"][meta["packageId"]] = meta["versionCode"]
    save(state)
    print("Success")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

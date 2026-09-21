"""Five phases: connect, plan, apply, verify, report.

One failing resource never aborts the run -- everything independent still
converges, and the exit code reports the failure at the end.
"""
from __future__ import annotations

import argparse
import sys

from .adb import Adb, DeviceOffline, DeviceUnauthorized
from .manifest import ManifestError, load
from .outcome import FAILED, Outcome
from .resources import apks, cacerts, device_owner, obtainium, settings

EXIT_OK = 0
EXIT_RESOURCE_FAILED = 1
EXIT_UNREACHABLE = 2
EXIT_UNAUTHORIZED = 3
EXIT_MANIFEST = 4

# Device Owner last: the DPC package must be installed before dpm can name it.
RESOURCES = (apks, settings, cacerts, obtainium, device_owner)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="android-provision")
    sub = parser.add_subparsers(dest="command", required=True)

    for name, help_text in (
        ("provision", "converge the device to the manifest"),
        ("plan", "show what provision would change, without touching the device"),
    ):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--manifest", required=True)
        if name == "provision":
            p.add_argument(
                "--force", action="store_true",
                help="re-apply marker-backed resources (CA certs, Obtainium)",
            )
    return parser


def report(outcomes: list[Outcome]) -> None:
    for o in outcomes:
        line = f"  {o.status:8} {o.resource}/{o.target}"
        if o.reason:
            line += f" -- {o.reason}"
        print(line)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    apply = args.command == "provision"
    force = getattr(args, "force", False)

    try:
        manifest = load(args.manifest)
    except ManifestError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_MANIFEST

    adb = Adb(manifest.host, manifest.port)
    try:
        info = adb.connect()
    except DeviceUnauthorized as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_UNAUTHORIZED
    except DeviceOffline as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_UNREACHABLE

    verb = "provisioning" if apply else "planning"
    print(f"{verb} {manifest.device} ({manifest.host}:{manifest.port}) "
          f"-- {info.model}, SDK {info.sdk}")

    outcomes: list[Outcome] = []
    for module in RESOURCES:
        outcomes.extend(module.reconcile(adb, info, manifest, apply=apply, force=force))

    report(outcomes)

    failed = [o for o in outcomes if o.status == FAILED]
    if failed:
        print(f"{len(failed)} resource(s) failed", file=sys.stderr)
        return EXIT_RESOURCE_FAILED
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

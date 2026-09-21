"""Resolve app identifiers to concrete, hashed APKs.

This is the only code that touches the network, and it runs only under
`nix run .#android-update`. Evaluation reads apks.lock.json and nothing else,
which is what keeps builds pure and a provision run independent of F-Droid
being up.

F-Droid metadata comes from index-v2, which is authoritative -- no APK parsing.
GitHub assets are parsed in-process with pyaxmlparser plus zipfile for ABIs.
"""
from __future__ import annotations

import base64
import fnmatch
import hashlib
import io
import json
import urllib.request
import zipfile

FDROID_INDEX = "https://f-droid.org/repo/index-v2.json"
FDROID_REPO = "https://f-droid.org/repo"
GITHUB_API = "https://api.github.com/repos/{repo}/releases/latest"
ABI_PREFIX = "lib/"


class ResolveError(Exception):
    """An app identifier could not be resolved to an APK."""


def sri(digest_hex: str) -> str:
    return "sha256-" + base64.b64encode(bytes.fromhex(digest_hex)).decode()


def resolve_fdroid(index: dict, package_id: str) -> dict:
    package = index.get("packages", {}).get(package_id)
    if package is None:
        raise ResolveError(f"{package_id} is not on F-Droid")

    versions = list(package.get("versions", {}).values())
    if not versions:
        raise ResolveError(f"{package_id} has no versions on F-Droid")

    top = max(v["manifest"]["versionCode"] for v in versions)
    # A multi-ABI app publishes one version per ABI with adjacent version codes,
    # all under the same versionName. Group by versionName so every ABI variant
    # of the newest release is kept. When several entries in the group share an
    # ABI, iterate in ascending versionCode order so the highest versionCode
    # wins that ABI slot -- keeping the pinned APK in agreement with the
    # versionCode recorded below.
    newest_name = next(
        v["manifest"]["versionName"] for v in versions if v["manifest"]["versionCode"] == top
    )
    chosen = [v for v in versions if v["manifest"]["versionName"] == newest_name]

    variants: dict[str, dict] = {}
    for v in sorted(chosen, key=lambda v: v["manifest"]["versionCode"]):
        manifest = v["manifest"]
        abis = manifest.get("nativecode") or ["universal"]
        for abi in abis:
            variants[abi] = {
                "url": FDROID_REPO + v["file"]["name"],
                "sha256": sri(v["file"]["sha256"]),
                "size": v["file"]["size"],
            }

    newest = max(chosen, key=lambda v: v["manifest"]["versionCode"])["manifest"]
    return {
        "source": "fdroid",
        "key": package_id,
        "packageId": package_id,
        "versionName": newest["versionName"],
        "versionCode": newest["versionCode"],
        "minSdk": newest.get("usesSdk", {}).get("minSdkVersion", 1),
        "variants": variants,
    }


def select_asset(release: dict, asset_glob: str) -> dict:
    matches = [a for a in release.get("assets", []) if fnmatch.fnmatch(a["name"], asset_glob)]
    if not matches:
        names = ", ".join(a["name"] for a in release.get("assets", [])) or "none"
        raise ResolveError(f"{asset_glob!r} matched no assets (available: {names})")
    if len(matches) > 1:
        names = ", ".join(a["name"] for a in matches)
        raise ResolveError(f"{asset_glob!r} matched {len(matches)} assets: {names}")
    return matches[0]


def apk_metadata(apk_bytes: bytes) -> dict:
    from pyaxmlparser import APK

    apk = APK(apk_bytes, raw=True)
    with zipfile.ZipFile(io.BytesIO(apk_bytes)) as zf:
        abis = sorted(
            {
                name[len(ABI_PREFIX):].split("/", 1)[0]
                for name in zf.namelist()
                if name.startswith(ABI_PREFIX) and "/" in name[len(ABI_PREFIX):]
            }
        )
    return {
        "packageId": apk.package,
        "versionCode": int(apk.version_code),
        "versionName": apk.version_name,
        "minSdk": int(apk.get_min_sdk_version() or 1),
        "abis": abis or ["universal"],
    }


def resolve_github(release: dict, repo: str, asset_glob: str, apk_bytes: bytes) -> dict:
    asset = select_asset(release, asset_glob)
    meta = apk_metadata(apk_bytes)
    digest = hashlib.sha256(apk_bytes).hexdigest()
    variant = {"url": asset["browser_download_url"], "sha256": sri(digest), "size": asset["size"]}
    return {
        "source": "github",
        "key": repo,
        "tag": release["tag_name"],
        "packageId": meta["packageId"],
        "versionName": meta["versionName"],
        "versionCode": meta["versionCode"],
        "minSdk": meta["minSdk"],
        "variants": {abi: variant for abi in meta["abis"]},
    }


def write_lockfile(path: str, entries: list[dict]) -> None:
    table = {entry["key"]: entry for entry in entries}
    with open(path, "w") as fh:
        json.dump(table, fh, indent=2, sort_keys=True)
        fh.write("\n")


def fetch_json(url: str, token: str | None = None) -> dict:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)


def fetch_bytes(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=300) as response:
        return response.read()

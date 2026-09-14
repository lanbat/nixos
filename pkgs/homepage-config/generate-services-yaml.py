#!/usr/bin/env python3
"""Build Homepage services.yaml from a Nix-generated manifest and agenix secrets."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import yaml


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def resolve_secret(spec: dict[str, Any], agenix_dir: Path) -> str | None:
    if "var" in spec:
        env = load_env_file(agenix_dir / spec["file"])
        return env.get(spec["var"]) or None
    path = agenix_dir / spec["file"]
    if not path.is_file():
        return None
    value = path.read_text().strip()
    return value or None


def resolve_value(value: Any, agenix_dir: Path) -> Any:
    if isinstance(value, dict):
        if "_secret" in value:
            spec = value["_secret"]
            if isinstance(spec, str):
                env = load_env_file(agenix_dir / "homepage-widgets-env")
                return env.get(spec) or None
            return resolve_secret(spec, agenix_dir)
        return {key: resolve_value(item, agenix_dir) for key, item in value.items()}
    if isinstance(value, list):
        return [resolve_value(item, agenix_dir) for item in value]
    return value


def widget_is_usable(widget: dict[str, Any]) -> bool:
    for key, value in widget.items():
        if key == "type":
            continue
        if value is None:
            return False
        if isinstance(value, str) and not value.strip():
            return False
    return True


def build_service(entry: dict[str, Any], agenix_dir: Path) -> dict[str, Any]:
    service: dict[str, Any] = {
        "href": entry["href"],
        "description": entry["description"],
    }
    if entry.get("icon"):
        service["icon"] = entry["icon"]
    if entry.get("widget"):
        widget = resolve_value(entry["widget"], agenix_dir)
        if widget_is_usable(widget):
            service["widget"] = widget
    return service


def build_yaml(manifest: dict[str, Any], agenix_dir: Path) -> list[dict[str, Any]]:
    groups: list[dict[str, Any]] = []
    for group in manifest["groups"]:
        services: list[dict[str, Any]] = []
        for entry in group["entries"]:
            services.append({entry["name"]: build_service(entry, agenix_dir)})
        if services:
            groups.append({group["name"]: services})
    return groups


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: generate-services-yaml.py <manifest.json> <agenix-dir> <output.yaml>",
            file=sys.stderr,
        )
        return 2

    manifest_path = Path(sys.argv[1])
    agenix_dir = Path(sys.argv[2])
    output_path = Path(sys.argv[3])

    manifest = json.loads(manifest_path.read_text())
    services = build_yaml(manifest, agenix_dir)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        yaml.safe_dump(
            services,
            sort_keys=False,
            allow_unicode=True,
            default_flow_style=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

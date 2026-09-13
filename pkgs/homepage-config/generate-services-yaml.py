#!/usr/bin/env python3
"""Build Homepage services.yaml from a Nix-generated manifest and agenix secrets."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


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


def build_services(manifest: dict[str, Any], agenix_dir: Path) -> dict[str, Any]:
    services: dict[str, Any] = {}
    for group in manifest["groups"]:
        entries: dict[str, Any] = {}
        for entry in group["entries"]:
            service = {
                "href": entry["href"],
                "description": entry["description"],
            }
            if entry.get("icon"):
                service["icon"] = entry["icon"]
            if entry.get("widget"):
                widget = resolve_value(entry["widget"], agenix_dir)
                if widget_is_usable(widget):
                    service["widget"] = widget
            entries[entry["name"]] = service
        if entries:
            services[group["name"]] = entries
    return services


def dump_yaml(data: dict[str, Any]) -> str:
    lines: list[str] = []

    def emit(value: Any, indent: int = 0) -> None:
        prefix = "  " * indent
        if isinstance(value, dict):
            for key, item in value.items():
                if isinstance(item, (dict, list)):
                    lines.append(f"{prefix}{key}:")
                    emit(item, indent + 1)
                elif isinstance(item, bool):
                    lines.append(f"{prefix}{key}: {'true' if item else 'false'}")
                else:
                    lines.append(f"{prefix}{key}: {json.dumps(item)}")
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, dict):
                    lines.append(f"{prefix}-")
                    emit(item, indent + 1)
                else:
                    lines.append(f"{prefix}- {json.dumps(item)}")
        else:
            lines.append(f"{prefix}{json.dumps(value)}")

    for group_name, entries in data.items():
        lines.append(f"{json.dumps(group_name)}:")
        for service_name, service in entries.items():
            lines.append(f"  {json.dumps(service_name)}:")
            emit(service, 2)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


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
    services = build_services(manifest, agenix_dir)
    output_path.parent.mkdir(parents = True, exist_ok = True)
    output_path.write_text(dump_yaml(services))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path


SEED_VERSION = "0.1.100"
SEMVER_RE = re.compile(r"^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$")


def parse_version(value: str) -> tuple[int, int, int]:
    match = SEMVER_RE.fullmatch(value.strip())
    if not match:
        raise ValueError(f"invalid semantic version: {value}")
    return tuple(int(part) for part in match.groups())


def format_version(parts: tuple[int, int, int]) -> str:
    return ".".join(str(part) for part in parts)


def read_json(path: Path) -> object | None:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None


def collect_manifest_versions(root: Path) -> set[str]:
    versions = {SEED_VERSION}
    for rel in ("releases/builds-manifest.json", "releases/releases-manifest.json", "releases/pre-releases-manifest.json"):
        data = read_json(root / rel)
        if not isinstance(data, dict):
            continue
        candidates: list[object] = []
        latest = data.get("latest")
        if latest is not None:
            candidates.append(latest)
        items = data.get("items")
        if isinstance(items, list):
            candidates.extend(items)
        for item in candidates:
            if not isinstance(item, dict):
                continue
            version = item.get("version")
            if isinstance(version, str) and SEMVER_RE.fullmatch(version):
                versions.add(version)
    return versions


def explicit_version_from_env(raw: str | None) -> tuple[str, str] | None:
    if raw and raw.strip():
        return raw.strip(), "input"
    if os.environ.get("GITHUB_REF_TYPE") == "tag":
        tag = os.environ.get("GITHUB_REF_NAME", "")
        if tag.startswith("v") and SEMVER_RE.fullmatch(tag[1:]):
            return tag[1:], "tag"
    return None


def write_output(name: str, value: str) -> None:
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")
    print(f"{name}={value}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve the public PEGPU semantic version.")
    parser.add_argument("--root", default=".", help="PEGPU repository root")
    parser.add_argument("--explicit", default="", help="Explicit release_version input")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    versions = collect_manifest_versions(root)
    latest = max((parse_version(version) for version in versions), default=parse_version(SEED_VERSION))

    explicit = explicit_version_from_env(args.explicit)
    if explicit is not None:
        version, source = explicit
        selected = parse_version(version)
        if source != "tag" and selected <= latest:
            raise SystemExit(
                f"release_version {version} is not newer than latest completed PEGPU version {format_version(latest)}"
            )
    else:
        selected = (latest[0], latest[1], latest[2] + 1)
        version = format_version(selected)

    build_number = version
    write_output("release_version", version)
    write_output("build_number", build_number)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

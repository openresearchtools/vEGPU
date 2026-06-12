#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_manifest(path: Path) -> dict:
    if not path.exists():
        return {"schemaVersion": 1, "updatedAt": "", "seedVersion": "0.1.100", "latest": None, "items": []}
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise SystemExit(f"build ledger is not a JSON object: {path}")
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description="Record a successful PEGPU package build.")
    parser.add_argument("--manifest", default="releases/builds-manifest.json")
    parser.add_argument("--version", required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--package-name", required=True)
    parser.add_argument("--package-size", required=True, type=int)
    parser.add_argument("--package-sha256", required=True)
    parser.add_argument("--display-mode", default="")
    parser.add_argument("--scaling-mode", default="")
    parser.add_argument("--performance-mode", default="")
    parser.add_argument("--machine-mode", default="")
    args = parser.parse_args()

    path = Path(args.manifest)
    data = read_manifest(path)
    created_at = now_iso()
    entry = {
        "version": args.version,
        "mode": args.mode,
        "packageName": args.package_name,
        "packageSize": args.package_size,
        "packageSHA256": args.package_sha256,
        "runId": os.environ.get("GITHUB_RUN_ID", ""),
        "sourceRevision": os.environ.get("GITHUB_SHA", ""),
        "sourceRef": os.environ.get("GITHUB_REF", ""),
        "createdAt": created_at,
        "components": {
            "display": args.display_mode,
            "scaling": args.scaling_mode,
            "performance": args.performance_mode,
            "machine": args.machine_mode,
        },
    }
    items = [item for item in data.get("items", []) if not (isinstance(item, dict) and item.get("version") == args.version)]
    items.insert(0, entry)
    data["schemaVersion"] = 1
    data.setdefault("seedVersion", "0.1.100")
    data["updatedAt"] = created_at
    data["latest"] = entry
    data["items"] = items[:100]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

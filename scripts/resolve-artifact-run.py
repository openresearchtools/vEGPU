#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def load_pages(path: Path) -> list[dict]:
    text = path.read_text(errors="replace")
    decoder = json.JSONDecoder()
    pages: list[dict] = []
    index = 0
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            break
        page, next_index = decoder.raw_decode(text, index)
        pages.append(page)
        index = next_index
    return pages


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: resolve-artifact-run.py artifacts-pages.json ARTIFACT_NAME...", file=sys.stderr)
        return 2

    required = set(sys.argv[2:])
    candidates: dict[str, dict[str, object]] = {}
    for page in load_pages(Path(sys.argv[1])):
        for artifact in page.get("artifacts", []):
            if artifact.get("expired"):
                continue
            name = artifact.get("name")
            if name not in required:
                continue
            run = artifact.get("workflow_run") or {}
            run_id = str(run.get("id") or "")
            if not run_id:
                continue
            entry = candidates.setdefault(run_id, {"names": set(), "created_at": ""})
            entry["names"].add(name)
            entry["created_at"] = max(str(entry["created_at"]), str(artifact.get("created_at") or ""))

    matches = [
        (str(entry["created_at"]), run_id)
        for run_id, entry in candidates.items()
        if required.issubset(entry["names"])
    ]
    if not matches:
        return 1
    matches.sort(reverse=True)
    print(matches[0][1])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vegpu-build"
BUILD_ROOT="${VEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
OUT="${1:-${VEGPU_LEGAL_BUILD_DIR:-$BUILD_ROOT/legal/generated}}"
REQUIRE_FULL_SOURCE="${VEGPU_REQUIRE_FULL_SOURCE:-0}"

rm -rf "$OUT"
mkdir -p "$OUT/licenses" "$OUT/source"

python3 - "$ROOT" "$OUT" "$REQUIRE_FULL_SOURCE" <<'PY'
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
out = Path(sys.argv[2])
require_full_source = sys.argv[3] == "1"
default_build_root = Path(
    os.environ.get("VEGPU_BUILD_ROOT")
    or os.path.join(os.environ.get("RUNNER_TEMP", tempfile.gettempdir()), "vegpu-build")
)

def exists_status(path: Path) -> str:
    return "present" if path.exists() else "missing"

def copy_license(rel: str, name: str | None = None) -> None:
    src = root / rel
    if not src.exists():
        return
    dst = out / "licenses" / (name or src.name)
    if src.is_dir():
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst)
    else:
        shutil.copy2(src, dst)

copy_license("third_party/angle/LICENSE", "ANGLE-LICENSE.txt")
copy_license("third_party/angle/SOURCE.md", "ANGLE-SOURCE.md")
copy_license("third_party/angle/IMPORT.txt", "ANGLE-IMPORT.txt")
copy_license("LICENSE", "vEGPU-App-Apache-2.0.txt")
copy_license("legal/LICENSES/CocoaSpice-Apache-2.0.txt", "CocoaSpice-LICENSE.txt")
copy_license("legal/LICENSES", "vEGPU-LICENSES")
copy_license("third_party/utm/README.md", "UTM-PATCH-README.md")
copy_license("legal/NOTICES.md", "vEGPU-NOTICES.md")
copy_license("legal/LICENSES/llama-swap-MIT.txt", "llama-swap-MIT.txt")
copy_license("legal/LICENSES/llama.cpp-MIT.txt", "llama.cpp-MIT.txt")
copy_license("ai/web-ui-app/NOTICE", "web-ui-app-NOTICE.txt")
copy_license("ai/gost-local-proxy/LICENSE", "gost-local-proxy-LICENSE.txt")
copy_license("ai/gost-local-proxy/NOTICE", "gost-local-proxy-NOTICE.txt")

def safe_name(value: str) -> str:
    return "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in value)

def copy_notice_files(src_dir: Path, dst_dir: Path) -> int:
    count = 0
    if not src_dir.exists():
        return count
    for pattern in ("LICENSE*", "LICENCE*", "NOTICE*", "COPYING*", "COPYRIGHT*"):
        for item in src_dir.glob(pattern):
            if not item.is_file():
                continue
            dst_dir.mkdir(parents=True, exist_ok=True)
            dst = dst_dir / item.name
            if dst.exists():
                try:
                    dst.chmod(0o644)
                except OSError:
                    pass
                dst.unlink()
            shutil.copy2(item, dst)
            count += 1
    return count

swift_license_count = 0
swift_checkout_roots: set[Path] = set()
swift_scratch = os.environ.get("SWIFT_BUILD_SCRATCH_PATH")
if swift_scratch:
    swift_checkout_roots.update(path for path in Path(swift_scratch).glob("**/checkouts/*") if path.is_dir())
for pattern in (".build/**/checkouts/*",):
    swift_checkout_roots.update(path for path in root.glob(pattern) if path.is_dir())
for checkout in sorted(swift_checkout_roots):
    swift_license_count += copy_notice_files(
        checkout,
        out / "licenses" / "swiftpm" / safe_name(checkout.name),
    )

go_license_count = 0
for gomod in sorted((root / "ai").glob("*/go.mod")):
    module_root = gomod.parent
    try:
        listing = subprocess.run(
            ["go", "list", "-m", "-json", "all"],
            cwd=module_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        ).stdout
    except FileNotFoundError:
        listing = ""
    decoder = json.JSONDecoder()
    index = 0
    while index < len(listing):
        while index < len(listing) and listing[index].isspace():
            index += 1
        if index >= len(listing):
            break
        try:
            obj, next_index = decoder.raw_decode(listing, index)
        except json.JSONDecodeError:
            break
        index = next_index
        module_path = obj.get("Path", "unknown")
        module_dir = obj.get("Dir")
        if not module_dir:
            continue
        go_license_count += copy_notice_files(
            Path(module_dir),
            out / "licenses" / "go" / safe_name(module_path),
        )

framework_rows: list[tuple[str, str, str]] = []
framework_dir = Path(
    os.environ.get(
        "VEGPU_DISPLAY_FRAMEWORKS_OUT",
        os.environ.get("VEGPU_DISPLAY_FRAMEWORKS_DIR", str(default_build_root / "display-frameworks" / "macos-arm64")),
    )
)
for info in sorted(framework_dir.glob("*.framework/Versions/A/Resources/Info.plist")):
    framework = info.parents[3].name
    try:
        with info.open("rb") as handle:
            plist = plistlib.load(handle)
    except Exception:
        plist = {}
    identifier = str(plist.get("CFBundleIdentifier", "unknown"))
    version = str(plist.get("CFBundleShortVersionString", "unknown"))
    framework_rows.append((framework, identifier, version))

package_pins: list[str] = []
resolved = root / "Package.resolved"
if resolved.exists():
    data = json.loads(resolved.read_text())
    for pin in data.get("pins", []):
        state = pin.get("state", {})
        package_pins.append(
            f"- {pin.get('identity', 'unknown')}: {pin.get('location', 'unknown')} "
            f"@ {state.get('revision', state.get('version', 'unknown'))}"
        )

go_modules: list[str] = []
for gomod in sorted((root / "ai").glob("*/go.mod")):
    lines = gomod.read_text(errors="replace").splitlines()
    module = next((line.split(maxsplit=1)[1] for line in lines if line.startswith("module ")), gomod.parent.name)
    go_version = next((line.split(maxsplit=1)[1] for line in lines if line.startswith("go ")), "unknown")
    requires = [line.strip() for line in lines if line.strip().startswith("require ")]
    go_modules.append(f"- {module} ({gomod.relative_to(root)}, Go {go_version}, {len(requires)} direct require lines)")

display_source_candidates = [
    Path(os.environ["VEGPU_DISPLAY_SOURCE_OUT"]) if os.environ.get("VEGPU_DISPLAY_SOURCE_OUT") else None,
    root / "legal" / "display-runtime-source.tar.zst",
    root / "legal" / "display-runtime-source.tar.gz",
    root / "legal" / "display-runtime-source.tar.xz",
    root / "legal" / "display-runtime-source",
]
display_source = next((item for item in display_source_candidates if item is not None and item.exists()), None)
display_source_manifest_path = None
if display_source is not None:
    if display_source.is_file():
        shutil.copy2(display_source, out / "source" / display_source.name)
        display_source_manifest_path = f"source/{display_source.name}"
    else:
        (out / "source" / "DISPLAY_RUNTIME_SOURCE_DIRECTORY.txt").write_text(
            f"Display runtime source directory is present in source tree at: {display_source}\n"
            "Release packaging should archive this directory next to vEGPU-app-source.tar.gz.\n"
        )
        try:
            display_source_manifest_path = str(display_source.relative_to(root))
        except ValueError:
            display_source_manifest_path = str(display_source)
elif require_full_source:
    raise SystemExit(
        "Missing display runtime corresponding source archive. Set VEGPU_DISPLAY_SOURCE_OUT "
        "to the downloaded display-runtime-source artifact, or set VEGPU_REQUIRE_FULL_SOURCE=0 "
        "for non-release local builds."
    )

machine_app = Path(os.environ.get("VEGPU_MACHINE_APP", "/Applications/vEGPU Machine.app"))
machine_notices = machine_app / "Contents" / "Resources" / "ThirdPartyNotices"
machine_source_bundles = machine_app / "Contents" / "Resources" / "SourceBundles"
machine_guest_source = machine_app / "Contents" / "Resources" / "guest-tools" / "source"

notice = []
notice.append("# vEGPU Licenses and Notices")
notice.append("")
notice.append("Generated from the current vEGPU source tree and bundle inputs.")
notice.append(f"Generated at: {datetime.now(timezone.utc).isoformat()}")
notice.append("")
notice.append("## Scope")
notice.append("")
notice.append("- vEGPU.app is the Swift/AppKit application and app-side display client.")
notice.append("- vEGPU Machine.app is the separate QEMU/VFIO/DriverKit runtime app.")
notice.append("- vEGPU Machine carries its own notices and GPL/source bundles inside that app.")
notice.append("- Legacy THIRD_PARTY_* notice files are not used by this generated bundle.")
notice.append("- The vEGPU Help menu can export the bundled source archives to a user-selected folder.")
notice.append("")
notice.append("## App-Side Bundled Display Runtime")
notice.append("")
notice.append("These frameworks are generated from the pinned UTM dependency recipe, copied into vEGPU.app/Contents/Frameworks during packaging, and loaded by the app-side SPICE/ANGLE display path.")
notice.append("")
notice.append("| Framework | Bundle identifier | Bundle version |")
notice.append("|---|---|---|")
for framework, identifier, version in framework_rows:
    notice.append(f"| {framework} | {identifier} | {version} |")
notice.append("")
notice.append("## Swift Package Pins")
notice.append("")
notice.extend(package_pins or ["- No remote Swift package pins found."])
notice.append("")
notice.append(f"SwiftPM license/notice files collected: {swift_license_count}")
notice.append("")
notice.append("## Go Modules")
notice.append("")
notice.extend(go_modules or ["- No Go modules found."])
notice.append("")
notice.append(f"Go module license/notice files collected: {go_license_count}")
notice.append("")
notice.append("## AI Web UI and Model Router Provenance")
notice.append("")
notice.append("The app-side AI web UI and router are not unmodified upstream llama.cpp or llama-swap distributions. Directory-specific provenance is copied to `licenses/web-ui-app-NOTICE.txt`; upstream MIT license texts are copied to `licenses/llama.cpp-MIT.txt` and `licenses/llama-swap-MIT.txt`.")
notice.append("Release packages bundle the latest llama.cpp ARM64 runtime build available at vEGPU release time from openresearchtools/llama-cpp-arm64-builds. Additional llama.cpp and TurboQuant runtime versions remain user-managed through /core.")
notice.append("")
notice.append("## Included License/Notice Files")
notice.append("")
for path in sorted((out / "licenses").rglob("*")):
    if path.is_file():
        notice.append(f"- licenses/{path.relative_to(out / 'licenses')}")
notice.append("")
notice.append("## Source Archives")
notice.append("")
notice.append("- source/vEGPU-app-source.tar.gz: generated from this vEGPU app source tree, excluding build products and runtime downloads.")
if display_source is not None:
    notice.append(f"- source/{display_source.name}: corresponding source/provenance supplied for generated display runtime frameworks.")
else:
    notice.append("- Display runtime corresponding source archive: missing in this checkout. Release builds should set VEGPU_REQUIRE_FULL_SOURCE=1 so this cannot be missed.")
notice.append("")
notice.append("## vEGPU Machine Notices")
notice.append("")
notice.append(f"- vEGPU Machine app: {machine_app} ({exists_status(machine_app)})")
notice.append(f"- vEGPU Machine notices: {machine_notices} ({exists_status(machine_notices)})")
notice.append(f"- vEGPU Machine source bundles: {machine_source_bundles} ({exists_status(machine_source_bundles)})")
notice.append(f"- vEGPU Machine guest source: {machine_guest_source} ({exists_status(machine_guest_source)})")
notice.append("")
notice.append("Use Help > Open vEGPU Machine or Help > Reveal vEGPU Machine Notices in vEGPU.app.")
notice.append("")

(out / "NOTICES.md").write_text("\n".join(notice))

manifest = {
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "frameworks": [
        {"framework": framework, "bundleIdentifier": identifier, "bundleVersion": version}
        for framework, identifier, version in framework_rows
    ],
    "swiftPins": package_pins,
    "goModules": go_modules,
    "displayRuntimeSource": display_source_manifest_path,
    "machineApp": str(machine_app),
    "machineNotices": str(machine_notices),
    "machineSourceBundles": str(machine_source_bundles),
}
(out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

source_items=()
for item in README.md LICENSE Package.swift Package.resolved Sources Resources Helpers ai scripts legal third_party docs; do
  if [ -e "$ROOT/$item" ]; then
    source_items+=("$item")
  fi
done

tar -czf "$OUT/source/vEGPU-app-source.tar.gz" \
  -C "$ROOT" \
  --exclude='.DS_Store' \
  --exclude='Resources/Guest/scaling-app/build' \
  --exclude='Resources/Guest/scaling-app/package' \
  --exclude='Resources/Guest/scaling-app/**/__pycache__' \
  --exclude='*.pyc' \
  --exclude='*.deb' \
  --exclude='ai/web-ui-app/runtimes' \
  --exclude='ai/web-ui-app/.runtime-downloads' \
  --exclude='ai/web-ui-app/llama-server' \
  --exclude='ai/web-ui-app/rpc-server' \
  --exclude='ai/web-ui-app/libggml*.dylib' \
  --exclude='ai/web-ui-app/libllama*.dylib' \
  --exclude='ai/web-ui-app/libmtmd*.dylib' \
  --exclude='ai/web-ui-app/web-ui-app' \
  --exclude='ai/gost-local-proxy/gost-local-proxy' \
  --exclude='tools/bin' \
  --exclude='THIRD_PARTY_*' \
  "${source_items[@]}"

echo "$OUT"

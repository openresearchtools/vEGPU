#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vegpu-build"
BUILD_ROOT="${VEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
OUT="${1:-${VEGPU_LEGAL_BUILD_DIR:-$BUILD_ROOT/legal/generated}}"
REQUIRE_FULL_SOURCE="${VEGPU_REQUIRE_FULL_SOURCE:-0}"

rm -rf "$OUT"
mkdir -p "$OUT/license-files" "$OUT/source"

python3 - "$ROOT" "$OUT" "$REQUIRE_FULL_SOURCE" <<'PY'
import json
import io
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
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
license_dir = out / "license-files"
generated_at = datetime.now(timezone.utc).isoformat()
source_revision = os.environ.get("GITHUB_SHA") or subprocess.run(
    ["git", "rev-parse", "HEAD"],
    cwd=root,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    check=False,
).stdout.strip() or "unknown"
release_version = os.environ.get("VERSION") or os.environ.get("RELEASE_VERSION") or "unknown"
utm_commit = os.environ.get("VEGPU_UTM_COMMIT") or "e4a4c34b671284263fc69f81b607de494d7e9b65"

def copy_license(rel: str, name: str | None = None) -> None:
    src = root / rel
    if not src.exists():
        return
    dst = license_dir / (name or src.name)
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
copy_license("legal/GUEST-VM-INSTALL-NOTICES.md", "GUEST-VM-INSTALL-NOTICES.md")
copy_license("legal/LICENSES/llama-swap-MIT.txt", "llama-swap-MIT.txt")
copy_license("legal/LICENSES/llama.cpp-MIT.txt", "llama.cpp-MIT.txt")
copy_license("ai/web-ui-app/NOTICE", "web-ui-app-NOTICE.txt")
copy_license("ai/gost-local-proxy/LICENSE", "gost-local-proxy-LICENSE.txt")
copy_license("ai/gost-local-proxy/NOTICE", "gost-local-proxy-NOTICE.txt")

guest_vm_install_notice = root / "legal" / "GUEST-VM-INSTALL-NOTICES.md"
if guest_vm_install_notice.exists():
    shutil.copy2(guest_vm_install_notice, out / "GUEST-VM-INSTALL-NOTICES.md")

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

archive_suffixes = (
    ".tar.gz",
    ".tgz",
    ".tar.xz",
    ".txz",
    ".tar.bz2",
    ".tbz2",
    ".tar",
)
max_archive_scan_depth = 8

license_name_prefixes = (
    "license",
    "licenses",
    "licence",
    "licences",
    "notice",
    "notices",
    "copying",
    "copyings",
    "copyright",
    "copyrights",
    "third_party_license",
    "third_party_licenses",
    "third-party-license",
    "third-party-licenses",
    "third_party_notice",
    "third_party_notices",
    "third-party-notice",
    "third-party-notices",
)

license_suffix_terms = {
    "agpl",
    "apache",
    "apl",
    "bsd",
    "buildtools",
    "exception",
    "gpl",
    "gpl2",
    "gpl3",
    "isc",
    "lgpl",
    "lgpl2",
    "lgpl21",
    "lgpl3",
    "lib",
    "lesser",
    "mit",
    "mpl",
    "new",
    "old",
    "openssl",
    "unlicense",
    "zlib",
}

license_text_extensions = {
    "adoc",
    "html",
    "htm",
    "md",
    "plist",
    "rst",
    "rtf",
    "text",
    "txt",
}

def archive_basename(name: str) -> str:
    base = Path(name).name
    lower = base.lower()
    for suffix in archive_suffixes:
        if lower.endswith(suffix):
            return base[: -len(suffix)]
    return Path(base).stem

def looks_like_archive(name: str) -> bool:
    lower = name.lower()
    return any(lower.endswith(suffix) for suffix in archive_suffixes)

def looks_like_license_path(name: str) -> bool:
    normalized = name.replace("\\", "/")
    parts = [part for part in normalized.split("/") if part and part not in {".", ".."}]
    if not parts:
        return False
    base = parts[-1].lower()
    for prefix in license_name_prefixes:
        if base == prefix:
            return True
        for separator in (".", "-", "_"):
            marker = prefix + separator
            if not base.startswith(marker):
                continue
            suffix = base[len(marker):]
            tokens = [token for token in re.split(r"[-_.]+", suffix) if token]
            if not tokens:
                return True
            if tokens[-1] in license_text_extensions:
                return True
            if any(
                token in license_suffix_terms
                or token.startswith("gpl")
                or token.startswith("lgpl")
                or token.startswith("agpl")
                for token in tokens
            ):
                return True
    return False

def safe_member_path(name: str) -> Path:
    parts = [
        safe_name(part)
        for part in name.replace("\\", "/").split("/")
        if part and part not in {".", ".."}
    ]
    return Path(*parts) if parts else Path("LICENSE")

def copy_tar_license_member(tar: tarfile.TarFile, member: tarfile.TarInfo, dst_root: Path) -> bool:
    if not member.isfile() or not looks_like_license_path(member.name):
        return False
    handle = tar.extractfile(member)
    if handle is None:
        return False
    dst = dst_root / safe_member_path(member.name)
    dst.parent.mkdir(parents=True, exist_ok=True)
    with handle, dst.open("wb") as out_file:
        shutil.copyfileobj(handle, out_file)
    return True

def collect_tar_license_files_from_tar(tar: tarfile.TarFile, dst_root: Path, label: str, depth: int) -> int:
    copied = 0
    for member in tar.getmembers():
        if copy_tar_license_member(tar, member, dst_root):
            copied += 1
            continue
        if depth >= max_archive_scan_depth or not member.isfile() or not looks_like_archive(member.name):
            continue
        handle = tar.extractfile(member)
        if handle is None:
            continue
        nested_root = dst_root / "nested-archives" / safe_name(archive_basename(member.name))
        with handle:
            data = handle.read()
        copied += collect_tar_license_files_from_bytes(
            data,
            nested_root,
            f"{label}!/{member.name}",
            depth + 1,
        )
    return copied

def collect_tar_license_files_from_file(archive: Path, dst_root: Path, depth: int = 0) -> int:
    copied = 0
    try:
        with tarfile.open(archive, mode="r:*") as tar:
            copied += collect_tar_license_files_from_tar(tar, dst_root, str(archive), depth)
    except (tarfile.TarError, OSError) as exc:
        if require_full_source:
            raise SystemExit(f"Unable to inspect legal source archive {archive}: {exc}") from exc
    return copied

def collect_tar_license_files_from_bytes(data: bytes, dst_root: Path, label: str, depth: int = 0) -> int:
    copied = 0
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tar:
            copied += collect_tar_license_files_from_tar(tar, dst_root, label, depth)
    except (tarfile.TarError, OSError) as exc:
        if require_full_source:
            raise SystemExit(f"Unable to inspect nested legal source archive {label}: {exc}") from exc
    return copied

def collect_display_runtime_licenses(display_source: Path | None) -> tuple[int, int]:
    if display_source is None or not display_source.is_file():
        return (0, 0)
    copied = 0
    archives = 0
    try:
        with tarfile.open(display_source, mode="r:*") as outer:
            for member in outer.getmembers():
                name = member.name.replace("\\", "/")
                if not member.isfile():
                    continue
                if looks_like_license_path(name) and name.startswith("display-runtime-source/"):
                    copied += 1 if copy_tar_license_member(
                        outer,
                        member,
                        license_dir / "display-runtime" / "source-bundle",
                    ) else 0
                    continue
                if not looks_like_archive(name):
                    continue
                if "/upstream-sources/" in name:
                    group = "upstream-sources"
                elif "/git-sources/" in name:
                    group = "git-sources"
                else:
                    continue
                handle = outer.extractfile(member)
                if handle is None:
                    continue
                archive_id = safe_name(archive_basename(name))
                with handle:
                    data = handle.read()
                archives += 1
                copied += collect_tar_license_files_from_bytes(
                    data,
                    license_dir / "display-runtime" / group / archive_id,
                    name,
                )
    except (tarfile.TarError, OSError) as exc:
        if require_full_source:
            raise SystemExit(f"Unable to inspect display runtime legal source archive {display_source}: {exc}") from exc
    if require_full_source and copied == 0:
        raise SystemExit(
            "Display runtime source archive was present but no license/notice files were harvested."
        )
    return (copied, archives)

def collect_llama_runtime_licenses(runtime_dir: Path | None, manifest: dict | None) -> tuple[int, int]:
    if runtime_dir is None or manifest is None:
        return (0, 0)
    copied = 0
    archives = 0
    assets = manifest.get("assets", {})
    if not isinstance(assets, dict):
        return (0, 0)
    for asset in assets.values():
        if not isinstance(asset, dict):
            continue
        path = str(asset.get("path") or "")
        if not path or not looks_like_archive(path):
            continue
        archive = (runtime_dir / path).resolve()
        try:
            archive.relative_to(runtime_dir.resolve())
        except ValueError:
            if require_full_source:
                raise SystemExit(f"Bundled llama runtime archive escapes runtime directory: {path}")
            continue
        if not archive.exists():
            if require_full_source:
                raise SystemExit(f"Bundled llama runtime archive missing: {archive}")
            continue
        archive_id = safe_name(archive_basename(str(asset.get("name") or archive.name)))
        archives += 1
        copied += collect_tar_license_files_from_file(
            archive,
            license_dir / "llama-runtime" / archive_id,
        )
    if require_full_source and archives > 0 and copied == 0:
        raise SystemExit(
            "Bundled llama runtime archives were present but no license/notice files were harvested."
        )
    return (copied, archives)

swift_license_count = 0
swift_checkout_roots: set[Path] = set()
swift_scratch = os.environ.get("SWIFT_BUILD_SCRATCH_PATH")
if swift_scratch:
    swift_checkout_roots.update(path for path in Path(swift_scratch).glob("**/checkouts/*") if path.is_dir())
for pattern in (".build/**/checkouts/*",):
    swift_checkout_roots.update(path for path in root.glob(pattern) if path.is_dir())
swift_license_counts_by_checkout: dict[str, int] = {}
for checkout in sorted(swift_checkout_roots):
    copied = copy_notice_files(
        checkout,
        license_dir / "swiftpm" / safe_name(checkout.name),
    )
    swift_license_count += copied
    swift_license_counts_by_checkout[checkout.name.lower()] = copied

if require_full_source:
    package_resolved = root / "Package.resolved"
    if package_resolved.exists():
        try:
            resolved = json.loads(package_resolved.read_text())
        except json.JSONDecodeError as exc:
            raise SystemExit(f"Package.resolved is not valid JSON: {exc}") from exc
        pins = resolved.get("pins", [])
        missing_swift_licenses: list[str] = []
        for pin in pins:
            if pin.get("kind") != "remoteSourceControl":
                continue
            identity = str(pin.get("identity") or "").lower()
            location_name = Path(str(pin.get("location") or "").removesuffix(".git")).name.lower()
            candidates = {identity, location_name}
            copied = sum(swift_license_counts_by_checkout.get(name, 0) for name in candidates)
            if copied == 0:
                missing_swift_licenses.append(identity or location_name or "<unknown>")
        if missing_swift_licenses:
            joined = ", ".join(sorted(set(missing_swift_licenses)))
            raise SystemExit(
                "Missing SwiftPM license/notice files for pinned packages: "
                f"{joined}. Build vEGPU.app after SwiftPM dependencies have been resolved, "
                "and pass SWIFT_BUILD_SCRATCH_PATH to the legal bundle builder."
            )

go_license_count = 0
go_module_meta: dict[str, dict[str, str]] = {}
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
        go_module_meta[safe_name(module_path)] = {
            "path": module_path,
            "version": obj.get("Version") or "workspace/current",
            "license": "See license text",
        }
        go_license_count += copy_notice_files(
            Path(module_dir),
            license_dir / "go" / safe_name(module_path),
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
package_pin_meta: dict[str, dict[str, str]] = {}
resolved = root / "Package.resolved"
if resolved.exists():
    data = json.loads(resolved.read_text())
    for pin in data.get("pins", []):
        state = pin.get("state", {})
        identity = pin.get("identity", "unknown")
        location = pin.get("location", "unknown")
        revision = state.get("revision", "unknown")
        version = state.get("version") or revision
        package_pins.append(
            f"- {identity}: {location} @ {revision}"
        )
        package_pin_meta[identity.lower()] = {
            "name": identity,
            "version": version,
            "revision": revision,
            "location": location,
            "license": "See license text",
        }

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
machine_notice_file = machine_notices / "NOTICES"
machine_license_file = machine_notices / "LICENSES"
machine_source_bundles = machine_app / "Contents" / "Resources" / "SourceBundles"
machine_guest_source = machine_app / "Contents" / "Resources" / "guest-tools" / "source"

angle_meta = {
    "version": "unknown",
    "license": "BSD",
    "source": "third_party/angle/ANGLE.plist",
}
angle_plist = root / "third_party" / "angle" / "ANGLE.plist"
if angle_plist.exists():
    try:
        with angle_plist.open("rb") as handle:
            angle_items = plistlib.load(handle)
        if angle_items:
            item = angle_items[0]
            angle_meta["version"] = str(item.get("OpenSourceVersion", "unknown"))
            angle_meta["license"] = str(item.get("OpenSourceLicense", "BSD"))
    except Exception:
        pass

llama_runtime_manifest_path = None
llama_runtime_manifest = None
bootstrap_llama_path = None
bootstrap_llama = os.environ.get("VEGPU_BOOTSTRAP_LLAMA_RUNTIME_DIR")
if bootstrap_llama:
    bootstrap_llama_path = Path(bootstrap_llama)
    candidate = bootstrap_llama_path / "llama-runtime-manifest.json"
    if candidate.exists():
        llama_runtime_manifest_path = candidate
        try:
            llama_runtime_manifest = json.loads(candidate.read_text())
        except json.JSONDecodeError as exc:
            if require_full_source:
                raise SystemExit(f"Bundled llama runtime manifest is invalid JSON: {exc}") from exc

display_runtime_license_count, display_runtime_source_archive_count = collect_display_runtime_licenses(display_source)
llama_runtime_license_count, llama_runtime_archive_count = collect_llama_runtime_licenses(bootstrap_llama_path, llama_runtime_manifest)

def read_text_lossy(path: Path) -> str:
    data = path.read_bytes()
    if not data:
        return ""
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        text = data.decode("utf-16", errors="replace")
    else:
        text = data.decode("utf-8", errors="replace")
    return text.replace("\x00", "").replace("\r\n", "\n").replace("\r", "\n").rstrip()

def guess_license_from_text(path: Path) -> str | None:
    lower = read_text_lossy(path).lower()
    if "gnu lesser general public license" in lower:
        return "LGPL"
    if "gnu general public license" in lower:
        return "GPL"
    if "apache license" in lower and "version 2.0" in lower:
        return "Apache-2.0"
    if "mozilla public license" in lower:
        return "MPL"
    if "permission is hereby granted, free of charge" in lower:
        return "MIT"
    if "redistribution and use in source and binary forms" in lower:
        return "BSD"
    if "isc license" in lower:
        return "ISC"
    if "zlib license" in lower:
        return "Zlib"
    return None

def license_guess(path: Path, rel: str) -> str:
    lower = rel.lower()
    name = path.name.lower()
    text_guess = guess_license_from_text(path)
    if text_guess:
        return text_guess
    if "apache-2.0" in lower or "apache" in name:
        return "Apache-2.0"
    if "mit" in lower:
        return "MIT"
    if "angle" in lower:
        return angle_meta["license"]
    if "notice" in lower or name.endswith(".md") or "source" in lower or "import" in lower:
        return "Notice/Provenance"
    return "See license text"

def name_version_from_archive_id(archive_id: str) -> tuple[str, str]:
    value = archive_id.replace("_", "-")
    match = re.match(r"(.+?)-([0-9][A-Za-z0-9_.+-]*)$", value)
    if match:
        return (match.group(1), match.group(2))
    if value.endswith("-source"):
        return (value[:-len("-source")], "source archive")
    return (value, "source archive")

def metadata_for_license_file(path: Path) -> dict[str, str]:
    rel = path.relative_to(license_dir).as_posix()
    lower = rel.lower()
    base = path.stem
    meta = {
        "name": re.sub(r"[-_]+", " ", base).strip() or rel,
        "version": "unknown",
        "license": license_guess(path, rel),
        "source": f"license-files/{rel}",
    }
    if rel == "vEGPU-App-Apache-2.0.txt":
        meta.update({"name": "vEGPU.app", "version": f"{release_version} ({source_revision})", "license": "Apache-2.0"})
    elif rel == "ANGLE-LICENSE.txt":
        meta.update({"name": "ANGLE", "version": angle_meta["version"], "license": angle_meta["license"]})
    elif rel in {"ANGLE-SOURCE.md", "ANGLE-IMPORT.txt"}:
        meta.update({"name": "ANGLE source provenance", "version": angle_meta["version"], "license": "Notice/Provenance"})
    elif rel == "CocoaSpice-LICENSE.txt":
        meta.update({"name": "CocoaSpice", "version": f"UTM {utm_commit}", "license": "Apache-2.0"})
    elif rel == "UTM-PATCH-README.md":
        meta.update({"name": "UTM/CocoaSpice patch provenance", "version": utm_commit, "license": "Notice/Provenance"})
    elif rel == "vEGPU-NOTICES.md":
        meta.update({"name": "vEGPU app notices seed", "version": source_revision, "license": "Notice/Provenance"})
    elif rel == "GUEST-VM-INSTALL-NOTICES.md":
        meta.update({"name": "vEGPU guest VM installation notices", "version": source_revision, "license": "Notice/Provenance"})
    elif "llama.cpp" in lower:
        meta.update({"name": "llama.cpp", "version": "bundled/runtime manifest", "license": "MIT"})
    elif "llama-swap" in lower:
        meta.update({"name": "llama-swap routing provenance", "version": "modified app-side routing", "license": "MIT"})
    elif "gost" in lower:
        meta.update({"name": "GOST/local proxy provenance", "version": "modified app-side local proxy", "license": "MIT" if "license" in lower or "mit" in lower else "Notice/Provenance"})
    elif "vegpu-scaling" in lower:
        meta.update({"name": "vEGPU Linux scaling helper", "version": release_version, "license": "MIT"})
    elif "utm-apache" in lower:
        meta.update({"name": "UTM app-side display provenance", "version": utm_commit, "license": "Apache-2.0"})
    elif lower.startswith("display-runtime/"):
        parts = rel.split("/")
        archive_id = parts[2] if len(parts) > 2 else Path(rel).stem
        package_name, package_version = name_version_from_archive_id(archive_id)
        meta.update({
            "name": f"Display runtime: {package_name}",
            "version": package_version,
            "license": license_guess(path, rel),
        })
    elif lower.startswith("llama-runtime/"):
        parts = rel.split("/")
        archive_id = parts[1] if len(parts) > 1 else Path(rel).stem
        version = (
            str(llama_runtime_manifest.get("tag") or "bundled/runtime archive")
            if isinstance(llama_runtime_manifest, dict)
            else "bundled/runtime archive"
        )
        meta.update({
            "name": f"Bundled llama.cpp runtime: {archive_id}",
            "version": version,
            "license": license_guess(path, rel),
        })
    elif lower.startswith("swiftpm/"):
        package = rel.split("/", 2)[1]
        pin = package_pin_meta.get(package.lower())
        if pin:
            meta.update({
                "name": f"SwiftPM: {pin['name']}",
                "version": f"{pin['version']} ({pin['revision']})",
                "license": pin["license"],
            })
        else:
            meta.update({"name": f"SwiftPM: {package}"})
    elif lower.startswith("go/"):
        module = rel.split("/", 2)[1]
        gometa = go_module_meta.get(module)
        if gometa:
            meta.update({
                "name": f"Go module: {gometa['path']}",
                "version": gometa["version"],
                "license": gometa["license"],
            })
        else:
            meta.update({"name": f"Go module: {module}"})
    return meta

license_blocks = []
duplicate_raw_license_paths = {
    "vEGPU-LICENSES/CocoaSpice-Apache-2.0.txt",
    "vEGPU-LICENSES/llama-swap-MIT.txt",
    "vEGPU-LICENSES/llama.cpp-MIT.txt",
    "vEGPU-LICENSES/gost-MIT.txt",
}
for path in sorted(license_dir.rglob("*")):
    if not path.is_file():
        continue
    rel_path = path.relative_to(license_dir).as_posix()
    if rel_path in duplicate_raw_license_paths:
        continue
    text = read_text_lossy(path)
    meta = metadata_for_license_file(path)
    license_blocks.append((meta, text))

license_lines = []
license_lines.append("vEGPU App Third-Party Licenses")
license_lines.append("================================")
license_lines.append("")
license_lines.append("Each package/dependency block below contains the package name, version or revision when known, license metadata, source license file copied into this notice bundle, and the full license or notice text between BEGIN LICENSE and END LICENSE markers.")
license_lines.append("")
license_lines.append("This file covers vEGPU.app app-side components only. QEMU, VFIO, DriverKit, firmware, and guest-driver licenses are carried by vEGPU Machine.app in /Applications/vEGPU Machine.app/Contents/Resources/ThirdPartyNotices/.")
license_lines.append("Machine/QEMU license text is not copied into this vEGPU.app LICENSES file. vEGPU.app Help can render external vEGPU Machine notices and licenses from the installed vEGPU Machine.app without copying those Machine files into vEGPU.app. vEGPU.app Help has external vEGPU Machine legal buttons that render those Machine files for convenience.")
license_lines.append("")
for meta, text in license_blocks:
    license_lines.append(f"Package/Dependency: {meta['name']}")
    license_lines.append(f"Version/Revision: {meta['version']}")
    license_lines.append(f"License: {meta['license']}")
    license_lines.append(f"Source-License-File: {meta['source']}")
    license_lines.append("----")
    license_lines.append("BEGIN LICENSE")
    license_lines.append("----")
    license_lines.append(text)
    license_lines.append("----")
    license_lines.append("END LICENSE")
    license_lines.append("")
(out / "LICENSES").write_text("\n".join(license_lines))

notice = []
notice.append("vEGPU Notices")
notice.append("=============")
notice.append("")
notice.append("This file covers vEGPU.app, the Swift/AppKit host application, app-side display client, AI/runtime control surface, local routing helpers, and app-side orchestration layer.")
notice.append("")
notice.append("vEGPU Machine.app is a separate application installed beside vEGPU.app. It owns the QEMU/VFIO/DriverKit/firmware/guest-driver runtime side and carries its own licenses, notices, and source bundles inside that app.")
notice.append("")
notice.append("Installed legal and source locations:")
notice.append("")
notice.append("- vEGPU.app notices: /Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated/NOTICES")
notice.append("- vEGPU.app licenses: /Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated/LICENSES")
notice.append("- vEGPU.app source: /Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated/source/vEGPU-app-source.tar.gz")
notice.append("- vEGPU app-side display/ANGLE source: /Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated/source/display-runtime-source.tar.gz")
notice.append("- vEGPU Machine notices: /Applications/vEGPU Machine.app/Contents/Resources/ThirdPartyNotices/NOTICES")
notice.append("- vEGPU Machine licenses: /Applications/vEGPU Machine.app/Contents/Resources/ThirdPartyNotices/LICENSES")
notice.append("- vEGPU Machine source bundles: /Applications/vEGPU Machine.app/Contents/Resources/SourceBundles/")
notice.append("- vEGPU Machine guest source: /Applications/vEGPU Machine.app/Contents/Resources/guest-tools/source/")
notice.append("- Guest VM install notices: /Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated/GUEST-VM-INSTALL-NOTICES.md")
notice.append("")
notice.append("QEMU-side licenses and notices are inside vEGPU Machine.app, not duplicated in vEGPU.app.")
notice.append("vEGPU.app Help can render external vEGPU Machine notices and licenses from the installed vEGPU Machine.app without copying those Machine files into vEGPU.app. vEGPU.app Help has external vEGPU Machine legal buttons that render those Machine files for convenience.")
notice.append("")
notice.append(f"Generated at: {generated_at}")
notice.append(f"vEGPU.app source revision: {source_revision}")
notice.append("")
notice.append("Scope")
notice.append("-----")
notice.append("")
notice.append("- vEGPU.app is the Swift/AppKit application and app-side display client.")
notice.append("- vEGPU Machine.app is the separate QEMU/VFIO/DriverKit runtime app.")
notice.append("- vEGPU Machine carries its own notices and GPL/source bundles inside that app.")
notice.append("- Legacy THIRD_PARTY_* notice files are not used by this generated bundle.")
notice.append("- The vEGPU Help menu opens Notices, Licenses, Guest VM Install Notices, and external vEGPU Machine legal files.")
notice.append("- The generated legal files list the installed source archive locations for vEGPU.app and vEGPU Machine.app.")
notice.append("")
notice.append("App-Side Bundled Display Runtime")
notice.append("---------------------------------")
notice.append("")
notice.append("These frameworks are generated from the pinned UTM dependency recipe, copied into vEGPU.app/Contents/Frameworks during packaging, and loaded by the app-side SPICE/ANGLE display path.")
notice.append("")
notice.append("| Framework | Bundle identifier | Bundle version |")
notice.append("|---|---|---|")
for framework, identifier, version in framework_rows:
    notice.append(f"| {framework} | {identifier} | {version} |")
notice.append("")
notice.append(f"Display runtime source archives scanned: {display_runtime_source_archive_count}")
notice.append(f"Display runtime license/notice files harvested: {display_runtime_license_count}")
notice.append("")
notice.append("Swift Package Pins")
notice.append("------------------")
notice.append("")
notice.extend(package_pins or ["- No remote Swift package pins found."])
notice.append("")
notice.append(f"SwiftPM license/notice files collected: {swift_license_count}")
notice.append("")
notice.append("Go Modules")
notice.append("----------")
notice.append("")
notice.extend(go_modules or ["- No Go modules found."])
notice.append("")
notice.append(f"Go module license/notice files collected: {go_license_count}")
notice.append("")
notice.append("AI Web UI and Model Router Provenance")
notice.append("-------------------------------------")
notice.append("")
notice.append("The app-side AI web UI and router are not unmodified upstream llama.cpp or llama-swap distributions. Directory-specific provenance is copied to `license-files/web-ui-app-NOTICE.txt`; upstream MIT license texts are copied to `license-files/llama.cpp-MIT.txt` and `license-files/llama-swap-MIT.txt`.")
notice.append("Release packages bundle the latest llama.cpp ARM64 runtime build available at vEGPU release time from openresearchtools/llama-cpp-arm64-builds. Additional llama.cpp and TurboQuant runtime versions remain user-managed through /core.")
if llama_runtime_manifest_path is not None:
    notice.append(f"Bundled llama.cpp runtime manifest input: {llama_runtime_manifest_path}")
notice.append(f"Bundled llama.cpp runtime archives scanned: {llama_runtime_archive_count}")
notice.append(f"Bundled llama.cpp runtime license/notice files harvested: {llama_runtime_license_count}")
notice.append("")
notice.append("Included License/Notice Files")
notice.append("-----------------------------")
notice.append("")
notice.append("- LICENSES: consolidated verbatim app-side license/notice text.")
for path in sorted(license_dir.rglob("*")):
    if path.is_file():
        notice.append(f"- license-files/{path.relative_to(license_dir)}")
notice.append("")
notice.append("Source Archives")
notice.append("---------------")
notice.append("")
notice.append("- source/vEGPU-app-source.tar.gz: generated from this vEGPU app source tree, excluding build products and runtime downloads.")
if display_source is not None:
    notice.append(f"- source/{display_source.name}: corresponding source/provenance supplied for generated display runtime frameworks, including ANGLE via the WebKit/ANGLE source snapshot.")
else:
    notice.append("- Display runtime corresponding source archive: missing in this checkout. Release builds should set VEGPU_REQUIRE_FULL_SOURCE=1 so this cannot be missed.")
notice.append("")
notice.append("vEGPU Machine Notices")
notice.append("---------------------")
notice.append("")
notice.append("These are external installed paths owned by vEGPU Machine.app. They are resolved and read when the user opens the external Machine legal buttons in vEGPU.app Help; vEGPU.app does not copy these Machine files into its own bundle.")
notice.append("")
notice.append(f"- vEGPU Machine app: {machine_app}")
notice.append(f"- vEGPU Machine notices: {machine_notice_file}")
notice.append(f"- vEGPU Machine licenses: {machine_license_file}")
notice.append(f"- vEGPU Machine source bundles: {machine_source_bundles}")
notice.append(f"- vEGPU Machine guest source: {machine_guest_source}")
notice.append("")
notice.append("Machine legal files and source bundle locations are listed above. vEGPU.app Help opens Notices, Licenses, Guest VM Install Notices, and external vEGPU Machine Notices/Licenses.")
notice.append("")

(out / "NOTICES").write_text("\n".join(notice))
(out / "NOTICES.md").write_text("\n".join(notice))

manifest = {
    "generatedAt": generated_at,
    "frameworks": [
        {"framework": framework, "bundleIdentifier": identifier, "bundleVersion": version}
        for framework, identifier, version in framework_rows
    ],
    "swiftPins": package_pins,
    "goModules": go_modules,
    "licenses": "LICENSES",
    "notices": "NOTICES",
    "guestVmInstallNotices": "GUEST-VM-INSTALL-NOTICES.md",
    "displayRuntimeSource": display_source_manifest_path,
    "displayRuntimeSourceArchivesScanned": display_runtime_source_archive_count,
    "displayRuntimeLicenseFiles": display_runtime_license_count,
    "llamaRuntimeArchivesScanned": llama_runtime_archive_count,
    "llamaRuntimeLicenseFiles": llama_runtime_license_count,
    "machineApp": str(machine_app),
    "machineNotices": str(machine_notice_file),
    "machineLicenses": str(machine_license_file),
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

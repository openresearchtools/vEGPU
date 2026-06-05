#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vegpu-build"
BUILD_ROOT="${VEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
OUT="${1:-${VEGPU_LEGAL_BUILD_DIR:-$BUILD_ROOT/legal/generated}}"
REQUIRE_FULL_SOURCE="${VEGPU_REQUIRE_FULL_SOURCE:-1}"

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

def decode_text_lossy(data: bytes) -> str:
    if not data:
        return ""
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        text = data.decode("utf-16", errors="replace")
    else:
        text = data.decode("utf-8", errors="replace")
    return text.replace("\x00", "").replace("\r\n", "\n").replace("\r", "\n").rstrip()

def primary_gnu_license_from_text(text: str) -> str | None:
    lower = text.lower()
    for match in re.finditer(r"gnu\s+(affero\s+)?(lesser\s+|library\s+)?general\s+public\s+license", lower):
        phrase = match.group(0)
        if "affero" in phrase:
            return "AGPL"
        if "lesser" in phrase or "library" in phrase:
            return "LGPL"
        return "GPL"
    return None

def bsd_license_id_from_text(text: str) -> str | None:
    lower = text.lower()
    if "redistribution and use in source and binary forms" not in lower:
        return None
    if "all advertising materials mentioning features or use of this software" in lower:
        return "BSD-4-Clause"
    if "neither the name" in lower or "nor the names of its contributors" in lower or "nor the names of their contributors" in lower:
        return "BSD-3-Clause"
    return "BSD"

def license_text_is_gpl_or_agpl(data: bytes) -> bool:
    return primary_gnu_license_from_text(decode_text_lossy(data)) in {"GPL", "AGPL"}

def copy_tar_license_member(tar: tarfile.TarFile, member: tarfile.TarInfo, dst_root: Path, member_filter=None, content_filter=None) -> bool:
    if not member.isfile() or not looks_like_license_path(member.name):
        return False
    if member_filter is not None and not member_filter(member.name):
        return False
    handle = tar.extractfile(member)
    if handle is None:
        return False
    with handle:
        data = handle.read()
    if content_filter is not None and not content_filter(member.name, data):
        return False
    dst = dst_root / safe_member_path(member.name)
    dst.parent.mkdir(parents=True, exist_ok=True)
    with dst.open("wb") as out_file:
        out_file.write(data)
    return True

def collect_tar_license_files_from_tar(tar: tarfile.TarFile, dst_root: Path, label: str, depth: int, member_filter=None, content_filter=None) -> int:
    copied = 0
    for member in tar.getmembers():
        if copy_tar_license_member(tar, member, dst_root, member_filter=member_filter, content_filter=content_filter):
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
            member_filter=member_filter,
            content_filter=content_filter,
        )
    return copied

def collect_tar_license_files_from_file(archive: Path, dst_root: Path, depth: int = 0, member_filter=None, content_filter=None) -> int:
    copied = 0
    try:
        with tarfile.open(archive, mode="r:*") as tar:
            copied += collect_tar_license_files_from_tar(tar, dst_root, str(archive), depth, member_filter=member_filter, content_filter=content_filter)
    except (tarfile.TarError, OSError) as exc:
        if require_full_source:
            raise SystemExit(f"Unable to inspect legal source archive {archive}: {exc}") from exc
    return copied

def collect_tar_license_files_from_bytes(data: bytes, dst_root: Path, label: str, depth: int = 0, member_filter=None, content_filter=None) -> int:
    copied = 0
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tar:
            copied += collect_tar_license_files_from_tar(tar, dst_root, label, depth, member_filter=member_filter, content_filter=content_filter)
    except (tarfile.TarError, OSError) as exc:
        if require_full_source:
            raise SystemExit(f"Unable to inspect nested legal source archive {label}: {exc}") from exc
    return copied

display_runtime_archive_allowlist = {
    "WebKit-source",
    "libepoxy-source",
    "libucontext-source",
    "gettext-0.22.5",
    "glib-2.83.0",
    "gst-plugins-base-1.19.1",
    "gst-plugins-good-1.19.1",
    "gstreamer-1.19.1",
    "json-glib-1.10.0",
    "libffi-3.5.0",
    "libgcrypt-1.8.4",
    "libgpg-error-1.38",
    "libiconv-1.16",
    "libjpeg-turbo-1.5.3",
    "libpng-1.6.48",
    "libsoup-3.6.0",
    "libusb-1.0.25",
    "libxml2-2.9.12",
    "openssl-1.1.1b",
    "opus-1.3",
    "phodav-3.0",
    "pixman-0.38.0",
    "spice-gtk-0.42",
    "spice-protocol-0.14.4",
    "usbredir-0.14.0",
    "utm-base-e4a4c34b671284263fc69f81b607de494d7e9b65",
    "zstd-1.5.2",
}

def display_runtime_archive_allowed(archive_id: str) -> bool:
    return archive_id in display_runtime_archive_allowlist

def display_runtime_license_member_allowed(archive_id: str, member_name: str) -> bool:
    normalized = member_name.replace("\\", "/").lower()
    if archive_id == "WebKit-source" and "/tools/flex-bison/" in normalized:
        return False
    if archive_id == "gettext-0.22.5":
        return "/gettext-runtime/intl/copying.lib" in normalized
    if archive_id == "libiconv-1.16":
        return normalized.endswith("/copying.lib")
    if archive_id in {"libgcrypt-1.8.4", "libgpg-error-1.38"}:
        return normalized.endswith("/copying.lib")
    if archive_id == "libpng-1.6.48":
        return normalized.endswith("/libpng-1.6.48/license")
    if archive_id == "spice-gtk-0.42" and "/common/recorder/scope/" in normalized:
        return False
    return True

def app_visible_display_license_content_allowed(member_name: str, data: bytes) -> bool:
    return not license_text_is_gpl_or_agpl(data)

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
                        content_filter=app_visible_display_license_content_allowed,
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
                if not display_runtime_archive_allowed(archive_id):
                    continue
                member_filter = lambda member_name, archive_id=archive_id: display_runtime_license_member_allowed(archive_id, member_name)
                copied += collect_tar_license_files_from_bytes(
                    data,
                    license_dir / "display-runtime" / group / archive_id,
                    name,
                    member_filter=member_filter,
                    content_filter=app_visible_display_license_content_allowed,
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

app_excluded_display_frameworks = {
    "asprintf.0.framework",
    "charset.1.framework",
    "gettextlib-0.22.5.framework",
    "gettextpo.0.framework",
    "gettextsrc-0.22.5.framework",
    "girepository-2.0.0.framework",
    "gstcheck-1.0.0.framework",
    "gstcontroller-1.0.0.framework",
    "textstyle.0.framework",
    "turbojpeg.0.framework",
}

framework_rows: list[tuple[str, str, str]] = []
framework_dir = Path(
    os.environ.get(
        "VEGPU_DISPLAY_FRAMEWORKS_OUT",
        os.environ.get("VEGPU_DISPLAY_FRAMEWORKS_DIR", str(default_build_root / "display-frameworks" / "macos-arm64")),
    )
)
for info in sorted(framework_dir.glob("*.framework/Versions/A/Resources/Info.plist")):
    framework = info.parents[3].name
    if framework in app_excluded_display_frameworks:
        continue
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
display_source_for_legal = display_source
if display_source is not None:
    (out / "source").mkdir(parents=True, exist_ok=True)
    if display_source.is_file():
        shutil.copy2(display_source, out / "source" / "display-runtime-source.tar.gz")
        display_source_for_legal = out / "source" / "display-runtime-source.tar.gz"
        display_source_manifest_path = "source/display-runtime-source.tar.gz"
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
        "to the downloaded display-runtime-source artifact. vEGPU.app package and artifact "
        "builds must always include this source archive and its generated legal sidecars."
    )

machine_app = Path(os.environ.get("VEGPU_MACHINE_APP", "/Applications/vEGPU Machine.app"))
machine_notices = machine_app / "Contents" / "Resources" / "ThirdPartyNotices"
machine_notice_file = machine_notices / "NOTICES"
machine_license_file = machine_notices / "LICENSES"
machine_source_bundles = machine_app / "Contents" / "Resources" / "SourceBundles"
machine_guest_source = machine_app / "Contents" / "Resources" / "guest-tools" / "source"

angle_meta = {
    "version": "unknown",
    "license": "BSD-3-Clause",
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
            raw_angle_license = str(item.get("OpenSourceLicense", "BSD"))
            if raw_angle_license.strip().upper() == "BSD":
                angle_license_text = root / "third_party" / "angle" / "LICENSE"
                if angle_license_text.exists():
                    raw_angle_license = bsd_license_id_from_text(read_text_lossy(angle_license_text.read_bytes())) or raw_angle_license
            angle_meta["license"] = raw_angle_license
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

display_runtime_license_count, display_runtime_source_archive_count = collect_display_runtime_licenses(display_source_for_legal)
llama_runtime_license_count, llama_runtime_archive_count = collect_llama_runtime_licenses(bootstrap_llama_path, llama_runtime_manifest)

def read_text_lossy(path: Path) -> str:
    return decode_text_lossy(path.read_bytes())

def guess_license_from_text(path: Path) -> str | None:
    lower = read_text_lossy(path).lower()
    gnu_license = primary_gnu_license_from_text(lower)
    if gnu_license:
        return gnu_license
    if "apache license" in lower and "version 2.0" in lower:
        return "Apache-2.0"
    if "mozilla public license" in lower:
        return "MPL"
    if "permission is hereby granted, free of charge" in lower:
        return "MIT"
    bsd_license = bsd_license_id_from_text(lower)
    if bsd_license:
        return bsd_license
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
        "scope": "vEGPU.app distribution",
        "source": f"license-files/{rel}",
    }
    if rel == "vEGPU-App-Apache-2.0.txt":
        meta.update({"name": "vEGPU.app", "version": f"{release_version} ({source_revision})", "license": "Apache-2.0", "scope": "vEGPU.app source code"})
    elif rel == "ANGLE-LICENSE.txt":
        meta.update({"name": "ANGLE", "version": angle_meta["version"], "license": angle_meta["license"], "scope": "Bundled app-side ANGLE runtime/source"})
    elif rel in {"ANGLE-SOURCE.md", "ANGLE-IMPORT.txt"}:
        meta.update({"name": "ANGLE source provenance", "version": angle_meta["version"], "license": "Notice/Provenance", "scope": "App-side source provenance"})
    elif rel == "CocoaSpice-LICENSE.txt":
        meta.update({"name": "CocoaSpice", "version": f"UTM {utm_commit}", "license": "Apache-2.0", "scope": "Bundled app-side display package"})
    elif rel == "UTM-PATCH-README.md":
        meta.update({"name": "UTM/CocoaSpice patch provenance", "version": utm_commit, "license": "Notice/Provenance", "scope": "App-side display patch provenance"})
    elif rel == "vEGPU-NOTICES.md":
        meta.update({"name": "vEGPU app notices seed", "version": source_revision, "license": "Notice/Provenance", "scope": "App-side notice seed"})
    elif rel == "GUEST-VM-INSTALL-NOTICES.md":
        meta.update({"name": "vEGPU guest VM installation notices", "version": source_revision, "license": "Notice/Provenance", "scope": "Guest VM install notice"})
    elif rel == "web-ui-app-NOTICE.txt":
        meta.update({"name": "AI web UI/router provenance", "version": source_revision, "license": "Notice/Provenance", "scope": "Bundled app-side AI web UI/router"})
    elif "llama.cpp" in lower:
        meta.update({"name": "llama.cpp", "version": "bundled/runtime manifest", "license": "MIT", "scope": "App-side llama.cpp runtime/provenance"})
    elif "llama-swap" in lower:
        meta.update({"name": "llama-swap routing provenance", "version": "modified app-side routing", "license": "MIT", "scope": "App-side routing provenance"})
    elif "gost" in lower:
        meta.update({"name": "GOST/local proxy provenance", "version": "modified app-side local proxy", "license": "MIT" if "license" in lower or "mit" in lower else "Notice/Provenance", "scope": "Bundled app-side local proxy"})
    elif "vegpu-scaling" in lower:
        meta.update({"name": "vEGPU Linux scaling helper", "version": release_version, "license": "MIT", "scope": "Bundled guest-side scaling helper package"})
    elif "utm-apache" in lower:
        meta.update({"name": "UTM app-side display provenance", "version": utm_commit, "license": "Apache-2.0", "scope": "App-side display provenance"})
    elif lower.startswith("display-runtime/"):
        parts = rel.split("/")
        archive_id = parts[2] if len(parts) > 2 else Path(rel).stem
        package_name, package_version = name_version_from_archive_id(archive_id)
        meta.update({
            "name": f"Display runtime: {package_name}",
            "version": package_version,
            "license": license_guess(path, rel),
            "scope": "Bundled app-side display runtime dependency",
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
            "scope": "Bundled app-managed llama.cpp runtime archive",
        })
    elif lower.startswith("swiftpm/"):
        package = rel.split("/", 2)[1]
        pin = package_pin_meta.get(package.lower())
        if pin:
            meta.update({
                "name": f"SwiftPM: {pin['name']}",
                "version": f"{pin['version']} ({pin['revision']})",
                "license": pin["license"],
                "scope": "Swift package used by vEGPU.app",
            })
        else:
            meta.update({"name": f"SwiftPM: {package}", "scope": "Swift package used by vEGPU.app"})
    elif lower.startswith("go/"):
        module = rel.split("/", 2)[1]
        gometa = go_module_meta.get(module)
        if gometa:
            meta.update({
                "name": f"Go module: {gometa['path']}",
                "version": gometa["version"],
                "license": gometa["license"],
                "scope": "Go module used by bundled app-side helper",
            })
        else:
            meta.update({"name": f"Go module: {module}", "scope": "Go module used by bundled app-side helper"})
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
license_lines.append("vEGPU.app Distribution Licenses")
license_lines.append("===============================")
license_lines.append("")
license_lines.append("Each package/dependency block below contains the package name, version or revision when known, license metadata, component scope, source license file copied into this notice bundle, and the full license or notice text between BEGIN LICENSE and END LICENSE markers.")
license_lines.append("")
license_lines.append("This LICENSES file is the consolidated license record for the installed vEGPU.app application/runtime distribution. It covers vEGPU.app's own application source license and the third-party software, runtime payloads, helper programs, framework dependencies, and app-managed runtime archives distributed as part of vEGPU.app.")
license_lines.append("vEGPU.app also installs corresponding source and provenance archives under legal/generated/source/. Those archives are provided to document and reproduce the app-side components they describe, and may contain upstream source trees, build recipes, backend implementations, generated inputs, tests, examples, and source-only build tools that are not loaded by vEGPU.app at runtime.")
license_lines.append("Each source archive has generated legal sidecars next to the archive: <archive>.NOTICES, <archive>.LICENSES, and <archive>.manifest.json. Those sidecars are the license and notice records for the files contained in the corresponding source archive. This app-visible LICENSES file does not flatten every source-archive license block into the runtime license view unless the same component is also distributed as an installed vEGPU.app runtime payload.")
license_lines.append("Machine/QEMU license text is not copied into this vEGPU.app LICENSES file. For convenience, vEGPU.app Help can render external vEGPU Machine notices and licenses from the installed vEGPU Machine.app. The Help menu marks those Machine-owned rows as EXTERNAL, and vEGPU.app does not copy Machine legal text into its own bundle.")
license_lines.append("")
for meta, text in license_blocks:
    license_lines.append(f"Package/Dependency: {meta['name']}")
    license_lines.append(f"Version/Revision: {meta['version']}")
    license_lines.append(f"License: {meta['license']}")
    license_lines.append(f"Component-Scope: {meta['scope']}")
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
notice.extend([
    "vEGPU Notices",
    "=============",
    "",
    "This is the canonical app-side NOTICES file installed inside vEGPU.app. It explains the vEGPU.app / vEGPU Machine.app split, where installed legal files and source bundles live, and how vEGPU.app Help exposes both app-side and external Machine-side legal files.",
    "",
    "vEGPU and vEGPU Machine are related applications, but they are distributed with a visible architecture, repository, license, notice, and source boundary. A combined installer may install both applications into /Applications, but the repositories, notices, source archives, runtime responsibilities, and license boundaries remain separate.",
    "",
    "Project website:",
    "https://vegpu.com",
    "",
    "",
    "1. vEGPU.app",
    "------------",
    "",
    "vEGPU.app is the host-side macOS application. It provides the Swift/AppKit launcher, tray/menu UI, UTM-derived embedded SPICE display client, ANGLE/CocoaSpice display integration, local AI/runtime controls, model/runtime routing helpers, file/port/terminal UI, sidecar metrics, local networking helpers, VM orchestration, guest setup/repair scripts, and app-side legal/source payload.",
    "",
    "Repository:",
    "https://github.com/openresearchtools/vEGPU",
    "",
    "The vEGPU.app application code is distributed under the Apache License, Version 2.0, except where an individual file or bundled component states a different license.",
    "",
    "vEGPU.app bundles, builds against, or ships app-side runtime components including SPICE, GLib, GStreamer, ANGLE, CocoaSpice, UTM-derived GUI display work, Swift package dependencies, Go helper dependencies, local AI web UI/router materials, llama.cpp and llama-swap derived/provenance materials, bundled llama.cpp runtime archives, GOST-style local proxy materials, TurboQuant runtime provenance, Linux scaling helper packaging, guest setup/repair scripts, and related support libraries. Those components keep their own license terms, including permissive licenses and LGPL-family licenses where applicable. File-level and component-level notices remain authoritative.",
    "",
    "The app-visible LICENSES file is the consolidated license record for the installed vEGPU.app application/runtime distribution. It covers vEGPU.app's own application source license and the third-party software, runtime payloads, helper programs, framework dependencies, and app-managed runtime archives distributed as part of vEGPU.app.",
    "",
    "vEGPU.app also installs corresponding source and provenance archives under legal/generated/source/. Those archives are provided to document and reproduce the app-side components they describe. Source archives are intentionally broader than the installed runtime closure: they may contain upstream source trees, build recipes, backend implementations, generated inputs, tests, examples, and source-only build tools that are present for provenance or reproducible-build purposes but are not loaded by vEGPU.app at runtime.",
    "",
    "The legal records for those source archive contents are generated next to each archive, not mixed into the main app runtime license view. For each archive, use the adjacent NOTICES, LICENSES, and manifest sidecars listed below.",
    "",
    "",
    "2. vEGPU Machine.app",
    "--------------------",
    "",
    "vEGPU Machine.app is the separate VM, DriverKit, VFIO, QEMU, firmware, and guest-tools runtime application used by vEGPU virtual machines. It owns the Machine-side passthrough mechanics and carries its own notices, license texts, and source bundles.",
    "",
    "Repository:",
    "https://github.com/openresearchtools/vEGPU-machine",
    "",
    "vEGPU Machine includes and packages Machine-side components including patched QEMU, the Apple VFIO backend, the DriverKit host application, the VFIOUserPCIDriver DriverKit system extension, the embedded qemu-vfio-apple launcher/CLI, QEMU firmware and runtime payloads, bundled QEMU tools and libraries, QEMU-side SPICE/virgl visual-runtime adaptations, guest-driver packages, and guest-side apple_dma DKMS source materials where included by the release.",
    "",
    "Machine-side notices, licenses, and source bundles are external installed files owned by vEGPU Machine.app. vEGPU.app does not copy those Machine files into its own bundle.",
    "",
    "",
    "3. Installed Legal And Source Files",
    "-----------------------------------",
    "",
    "Installed app-side notices, license texts, source records, and corresponding source/provenance archives are available at:",
    "",
    "/Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated",
    "",
    "Key installed vEGPU.app legal/source files:",
    "",
    "- NOTICES",
    "- LICENSES",
    "- GUEST-VM-INSTALL-NOTICES.md",
    "- source/vEGPU-app-source.tar.gz",
    "- source/vEGPU-app-source.NOTICES",
    "- source/vEGPU-app-source.LICENSES",
    "- source/vEGPU-app-source.manifest.json",
    "- source/display-runtime-source.tar.gz",
    "- source/display-runtime-source.NOTICES",
    "- source/display-runtime-source.LICENSES",
    "- source/display-runtime-source.manifest.json",
    "",
    "Installed Machine-side notices, license texts, and source bundles are available inside:",
    "",
    "/Applications/vEGPU Machine.app/Contents/Resources",
    "",
    "Key installed vEGPU Machine legal/source files:",
    "",
    "- ThirdPartyNotices/NOTICES",
    "- ThirdPartyNotices/LICENSES",
    "- SourceBundles/",
    "- guest-tools/source/",
    "",
    "Guest VM Installation Notice",
    "----------------------------",
    "",
    "GUEST-VM-INSTALL-NOTICES.md describes Debian APT, GUI, DMA driver, vEGPU guest scripts, vEGPU Machine guest packages, and optional NVIDIA/CUDA install activity inside the Linux VM.",
    "",
    "",
    "Help Menu Access",
    "----------------",
    "",
    "The vEGPU.app Help menu opens the installed legal files directly:",
    "",
    "- Notices",
    "- Licenses",
    "- VM Install Notices",
    "- EXTERNAL vEGPU Machine Notices",
    "- EXTERNAL vEGPU Machine Licenses",
    "",
    "For convenience, vEGPU.app Help can render external vEGPU Machine notices and licenses from the installed vEGPU Machine.app. The Help menu marks those Machine-owned rows as EXTERNAL. They do not duplicate or embed Machine legal text into vEGPU.app.",
    "",
    "",
    "License and architecture boundary",
    "---------------------------------",
    "",
    "vEGPU uses a stricter form of the UTM / UTM-QEMU-style architecture: the frontend, AI/runtime control surface, display client, routing, and orchestration app is packaged separately from the GPL-covered Machine/QEMU VM/runtime stack. The two apps have separate repositories, notices, source archives, and runtime responsibilities.",
    "",
    "- vEGPU.app contains the Apache-licensed launcher, GUI, app-side display client, AI/runtime controls, local routing helpers, guest setup/repair scripts, and orchestration code.",
    "- vEGPU Machine.app contains the GPL-covered QEMU-derived VM runtime, Apple VFIO backend, DriverKit host extension, firmware/runtime payloads, and guest-driver packaging.",
    "",
    "GPL-covered QEMU-derived code stays on the Machine side. App-side launcher, display, AI, guest provisioning, and orchestration work stays in vEGPU.app unless an individual bundled component states otherwise. QEMU-side licenses and notices are inside vEGPU Machine.app, not duplicated in vEGPU.app. Machine/QEMU license text is not copied into the vEGPU.app LICENSES file.",
    "",
    "Generated Metadata",
    "------------------",
    "",
    "Build-time legal harvesting details are kept in manifest.json, in the app-visible LICENSES blocks, and in the source-archive sidecar manifests for validation. This NOTICES file is intentionally a readable packaging and license-boundary explanation, not a raw inventory of every harvested license file.",
    "",
    "No Affiliation",
    "--------------",
    "",
    "vEGPU and vEGPU Machine are not endorsed by, sponsored by, or affiliated with Apple, NVIDIA, Fabrice Bellard, the QEMU project, Scott J. Goldman, scottjg/qemu-vfio-apple, UTM, utmapp/qemu, utmapp/virglrenderer, llama.cpp, llama-swap, GOST, TurboQuant, or their maintainers.",
    "",
])

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

python3 - "$OUT" <<'PY'
import hashlib
import io
import json
import os
import re
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path

out = Path(sys.argv[1])
source_dir = out / "source"
generated_at = datetime.now(timezone.utc).isoformat()

archive_suffixes = (".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tar")
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
license_text_extensions = {"adoc", "html", "htm", "md", "plist", "rst", "rtf", "text", "txt"}

def archive_base(path: Path) -> str:
    name = path.name
    lower = name.lower()
    for suffix in archive_suffixes:
        if lower.endswith(suffix):
            return name[: -len(suffix)]
    return path.stem

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

def decode_text_lossy(data: bytes) -> str:
    if not data:
        return ""
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        text = data.decode("utf-16", errors="replace")
    else:
        text = data.decode("utf-8", errors="replace")
    return text.replace("\x00", "").replace("\r\n", "\n").replace("\r", "\n").rstrip()

def primary_gnu_license_from_text(text: str) -> str | None:
    lower = text.lower()
    for match in re.finditer(r"gnu\s+(affero\s+)?(lesser\s+|library\s+)?general\s+public\s+license", lower):
        phrase = match.group(0)
        if "affero" in phrase:
            return "AGPL"
        if "lesser" in phrase or "library" in phrase:
            return "LGPL"
        return "GPL"
    return None

def bsd_license_id_from_text(text: str) -> str | None:
    lower = text.lower()
    if "redistribution and use in source and binary forms" not in lower:
        return None
    if "all advertising materials mentioning features or use of this software" in lower:
        return "BSD-4-Clause"
    if "neither the name" in lower or "nor the names of its contributors" in lower or "nor the names of their contributors" in lower:
        return "BSD-3-Clause"
    return "BSD"

def guess_license(text: str, path: str) -> str:
    lower = text.lower()
    path_lower = path.lower()
    gnu_license = primary_gnu_license_from_text(lower)
    if gnu_license:
        return gnu_license
    if "apache license" in lower and "version 2.0" in lower:
        return "Apache-2.0"
    if "mozilla public license" in lower:
        return "MPL"
    if "permission is hereby granted, free of charge" in lower:
        return "MIT"
    bsd_license = bsd_license_id_from_text(lower)
    if bsd_license:
        return bsd_license
    if "isc license" in lower:
        return "ISC"
    if "zlib license" in lower or "zlib/libpng license" in lower:
        return "Zlib"
    if "notice" in path_lower:
        return "Notice"
    return "See text"

def collect_from_tar_bytes(data: bytes, label: str, depth: int = 0, max_depth: int = 8):
    records = []
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tar:
            for member in tar.getmembers():
                name = member.name.replace("\\", "/")
                if not member.isfile():
                    continue
                handle = tar.extractfile(member)
                if handle is None:
                    continue
                with handle:
                    member_data = handle.read()
                archive_path = f"{label}!/{name}" if label else name
                if looks_like_license_path(name):
                    text = decode_text_lossy(member_data)
                    records.append({
                        "archivePath": archive_path,
                        "license": guess_license(text, archive_path),
                        "sha256": hashlib.sha256(member_data).hexdigest(),
                        "size": len(member_data),
                        "text": text,
                    })
                if depth < max_depth and looks_like_archive(name):
                    records.extend(collect_from_tar_bytes(member_data, archive_path, depth + 1, max_depth))
    except (tarfile.TarError, OSError):
        return records
    return records

def write_source_sidecars(archive: Path, title: str, description: str) -> None:
    if not archive.is_file():
        return
    data = archive.read_bytes()
    records = collect_from_tar_bytes(data, archive.name)
    prefix = source_dir / archive_base(archive)
    rel_archive = f"source/{archive.name}"
    notice_lines = [
        f"{title} Notices",
        "=" * (len(title) + len(" Notices")),
        "",
        f"Archive: {rel_archive}",
        f"Generated: {generated_at}",
        "",
        description,
        "",
        "This sidecar belongs to the source/provenance archive named above. The archive is distributed so the corresponding app-side artifacts can be inspected, audited, and reproduced from their recorded source inputs.",
        "",
        "Source archives are intentionally broader than the installed runtime closure. They may contain upstream source trees, build recipes, backend implementations, generated inputs, tests, examples, and source-only build tools that are present for provenance or reproducible-build purposes but are not loaded by vEGPU.app at runtime.",
        "",
        "Use this sidecar together with the adjacent LICENSES and manifest files for the archive contents:",
        "",
        f"- {prefix.name}.NOTICES",
        f"- {prefix.name}.LICENSES",
        f"- {prefix.name}.manifest.json",
        "",
    ]
    (prefix.with_suffix(".NOTICES")).write_text("\n".join(notice_lines))

    license_lines = [
        f"{title} Source Archive Licenses",
        "=" * (len(title) + len(" Source Archive Licenses")),
        "",
        f"Archive: {rel_archive}",
        f"Generated: {generated_at}",
        "",
        "This LICENSES sidecar contains license and notice text harvested from the source/provenance archive named above, including nested source archives where they are present. It governs the files contained in that source archive. It is separate from the main app-visible vEGPU.app LICENSES file, which covers the installed application/runtime distribution.",
        "",
    ]
    for record in records:
        license_lines.append(f"Archive-Path: {record['archivePath']}")
        license_lines.append(f"Detected-License: {record['license']}")
        license_lines.append(f"SHA256: {record['sha256']}")
        license_lines.append("----")
        license_lines.append("BEGIN LICENSE")
        license_lines.append("----")
        license_lines.append(record["text"])
        license_lines.append("----")
        license_lines.append("END LICENSE")
        license_lines.append("")
    (prefix.with_suffix(".LICENSES")).write_text("\n".join(license_lines))

    manifest = {
        "archive": rel_archive,
        "generatedAt": generated_at,
        "licenseRecordCount": len(records),
        "records": [
            {
                "archivePath": record["archivePath"],
                "detectedLicense": record["license"],
                "sha256": record["sha256"],
                "size": record["size"],
            }
            for record in records
        ],
    }
    (prefix.with_suffix(".manifest.json")).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

write_source_sidecars(
    source_dir / "vEGPU-app-source.tar.gz",
    "vEGPU.app",
    "This archive contains the vEGPU.app source tree used for the release, excluding generated build products, runtime downloads, local model files, VM disks, and other non-source artifacts.",
)
write_source_sidecars(
    source_dir / "display-runtime-source.tar.gz",
    "vEGPU.app Display Runtime",
    "This archive contains app-side display runtime source and provenance inputs used for the packaged SPICE/GLib/GStreamer/ANGLE display stack.",
)
PY

echo "$OUT"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION="${VERSION:-${RELEASE_VERSION:-0.1.0}}"
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pegpu-build"
BUILD_ROOT="${PEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
APP_BUILD_DIR="${PEGPU_APP_BUILD_DIR:-$BUILD_ROOT/app-build}"
SWIFT_BUILD_SCRATCH_PATH="${SWIFT_BUILD_SCRATCH_PATH:-$BUILD_ROOT/swiftpm-$CONFIGURATION}"
APP="${PEGPU_APP:-$BUILD_ROOT/PEGPU.app}"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
BUNDLED_ROOT="$RESOURCES/PEGPURoot"
DISPLAY_FRAMEWORKS="${PEGPU_DISPLAY_FRAMEWORKS_OUT:-$BUILD_ROOT/display-frameworks/macos-arm64}"
DISPLAY_ARTIFACT_NAME="${PEGPU_DISPLAY_ARTIFACT_NAME:-PEGPU-display-frameworks-legacy-macos13_5-arm64}"
MACOS_DEPLOYMENT_TARGET="${PEGPU_MACOS_DEPLOYMENT_TARGET:-${MACOSX_DEPLOYMENT_TARGET:-13.5}}"
ANGLE_NOTICE_DIR="${PEGPU_ANGLE_NOTICE_DIR:-$ROOT/third_party/angle}"
LEGAL_BUILD_DIR="${PEGPU_LEGAL_BUILD_DIR:-$BUILD_ROOT/legal/generated}"
SCALING_PACKAGE_DIR="${PEGPU_SCALING_PACKAGE_DIR:-}"
PERFORMANCE_PACKAGE_DIR="${PEGPU_PERFORMANCE_PACKAGE_DIR:-}"
BOOTSTRAP_LLAMA_RUNTIME_DIR="${PEGPU_BOOTSTRAP_LLAMA_RUNTIME_DIR:-}"
WEB_UI_BIN="$APP_BUILD_DIR/web-ui-app"
GOST_BIN="$APP_BUILD_DIR/gost-local-proxy"
AUDIO_HOST_BIN="$APP_BUILD_DIR/tools/bin/pegpu-audio-host"
LOCAL_PROXY_BIN="$APP_BUILD_DIR/tools/bin/pegpu-local-proxy"
ANGLE_REQUIRED_FRAMEWORKS=(EGL GLESv2)
APP_EXCLUDED_DISPLAY_FRAMEWORKS=(
  asprintf.0
  charset.1
  gettextlib-0.22.5
  gettextpo.0
  gettextsrc-0.22.5
  girepository-2.0.0
  gstcheck-1.0.0
  gstcontroller-1.0.0
  textstyle.0
  turbojpeg.0
)

cd "$ROOT"

missing_angle_frameworks=()
for framework in "${ANGLE_REQUIRED_FRAMEWORKS[@]}"; do
  if [ ! -d "$DISPLAY_FRAMEWORKS/$framework.framework" ]; then
    missing_angle_frameworks+=("$framework.framework")
  fi
done
if [ "${#missing_angle_frameworks[@]}" -gt 0 ]; then
  printf 'Missing app-side display framework(s): %s\n' "${missing_angle_frameworks[*]}" >&2
  printf 'Build or download the %s artifact and set PEGPU_DISPLAY_FRAMEWORKS_OUT.\n' "$DISPLAY_ARTIFACT_NAME" >&2
  exit 1
fi
for notice in SOURCE.md ANGLE.plist LICENSE; do
  if [ ! -f "$ANGLE_NOTICE_DIR/$notice" ]; then
    printf 'Missing app-side ANGLE notice metadata: %s\n' "$ANGLE_NOTICE_DIR/$notice" >&2
    exit 1
  fi
done

mkdir -p "$APP_BUILD_DIR/tools/bin"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
export PEGPU_BUILD_ROOT="$BUILD_ROOT"
export PEGPU_DISPLAY_FRAMEWORKS_OUT="$DISPLAY_FRAMEWORKS"
export PEGPU_UTM_PATCHED_WORKTREE="${PEGPU_UTM_PATCHED_WORKTREE:-$BUILD_ROOT/utm-patched}"
export PEGPU_COCOASPICE_PACKAGE_PATH="${PEGPU_COCOASPICE_PACKAGE_PATH:-$PEGPU_UTM_PATCHED_WORKTREE/OpenResearchTools/CocoaSpice}"
"$ROOT/scripts/apply-utm-patches.sh" >/dev/null
swift build --configuration "$CONFIGURATION" --disable-sandbox --scratch-path "$SWIFT_BUILD_SCRATCH_PATH"
SWIFT_BUILD_DIR="$(cd "$SWIFT_BUILD_SCRATCH_PATH/$CONFIGURATION" && pwd -P)"

(cd "$ROOT/ai/web-ui-app" && go build -o "$WEB_UI_BIN" .)
(cd "$ROOT/ai/gost-local-proxy" && go build -o "$GOST_BIN" .)
SDKROOT="$(xcrun --show-sdk-path)"
"$(xcrun --find clang)" -isysroot "$SDKROOT" -O2 -Wall -Wextra \
  -mmacosx-version-min="$MACOS_DEPLOYMENT_TARGET" \
  -framework AudioToolbox -framework CoreAudio \
  -o "$AUDIO_HOST_BIN" \
  "$ROOT/Helpers/AudioBridge/pegpu-audio-host.c"
cp "$GOST_BIN" "$LOCAL_PROXY_BIN"
chmod +x "$WEB_UI_BIN" "$GOST_BIN" "$LOCAL_PROXY_BIN" "$AUDIO_HOST_BIN"
export PEGPU_REQUIRE_FULL_SOURCE="${PEGPU_REQUIRE_FULL_SOURCE:-1}"
"$ROOT/scripts/build-legal-bundle.sh" "$LEGAL_BUILD_DIR" >/dev/null
required_legal_sidecars=(
  "$LEGAL_BUILD_DIR/source/PEGPU-app-source.NOTICES"
  "$LEGAL_BUILD_DIR/source/PEGPU-app-source.LICENSES"
  "$LEGAL_BUILD_DIR/source/PEGPU-app-source.manifest.json"
  "$LEGAL_BUILD_DIR/source/display-runtime-source.NOTICES"
  "$LEGAL_BUILD_DIR/source/display-runtime-source.LICENSES"
  "$LEGAL_BUILD_DIR/source/display-runtime-source.manifest.json"
)
for legal_file in "${required_legal_sidecars[@]}"; do
  if [ ! -f "$legal_file" ]; then
    printf 'Missing generated source archive legal sidecar: %s\n' "$legal_file" >&2
    exit 1
  fi
done
if awk '/^License:/ && $0 ~ /(GPL|AGPL)/ && $0 !~ /LGPL/ {print; bad=1} END {exit bad ? 0 : 1}' "$LEGAL_BUILD_DIR/LICENSES"; then
  printf 'PEGPU.app runtime/distribution LICENSES must not contain GPL-only dependency blocks.\n' >&2
  exit 1
fi
if grep -E 'The following are distributed under GPL v2|gst-plugins-base-1[.]15[.]2[.]tar[.]xz|qemu-4[.]2[.]0[.]tar[.]xz' "$LEGAL_BUILD_DIR/LICENSES"; then
  printf 'PEGPU.app LICENSES must not include UTM aggregate app license text; use UTM Apache license/provenance instead.\n' >&2
  exit 1
fi
if grep -E 'The following are distributed under GPL v2|gst-plugins-base-1[.]15[.]2[.]tar[.]xz|qemu-4[.]2[.]0[.]tar[.]xz' "$LEGAL_BUILD_DIR/source/"*.LICENSES; then
  printf 'PEGPU.app source sidecar licenses must not include UTM aggregate app license text; use source-specific licenses/provenance instead.\n' >&2
  exit 1
fi
if find "$LEGAL_BUILD_DIR/license-files" -type f | awk '{ lower=tolower($0); if ((lower ~ /agpl/ || lower ~ /gpl/) && lower !~ /lgpl/) { print; bad=1 } } END { exit bad ? 0 : 1 }'; then
  printf 'PEGPU.app legal payload must not copy GPL/AGPL-only source license files into app-visible license-files.\n' >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS" "$BUNDLED_ROOT/tools/bin"

cp "$SWIFT_BUILD_DIR/PEGPUApp" "$MACOS/PEGPU"
cp "$SWIFT_BUILD_DIR/pegpu" "$BUNDLED_ROOT/tools/bin/pegpu"
chmod +x "$MACOS/PEGPU" "$BUNDLED_ROOT/tools/bin/pegpu"
while IFS= read -r bundle; do
  rm -rf "$RESOURCES/$(basename "$bundle")"
  /usr/bin/ditto "$bundle" "$RESOURCES/$(basename "$bundle")"
done < <(find "$SWIFT_BUILD_DIR" -maxdepth 1 -type d -name '*.bundle' | sort)

cp "$ROOT/Package.swift" "$BUNDLED_ROOT/Package.swift"
rsync -a \
  --exclude='Guest/scaling-app/build/***' \
  --exclude='Guest/scaling-app/**/__pycache__/***' \
  --exclude='Guest/scaling-app/**/*.pyc' \
  --exclude='Guest/performance-app/**/__pycache__/***' \
  --exclude='Guest/performance-app/**/*.pyc' \
  "$ROOT/Resources" "$BUNDLED_ROOT/"
rsync -a \
  --exclude='web-ui-app/runtimes/***' \
  --exclude='web-ui-app/.runtime-downloads/***' \
  --exclude='web-ui-app/llama-server' \
  --exclude='web-ui-app/rpc-server' \
  --exclude='web-ui-app/libggml*.dylib' \
  --exclude='web-ui-app/libllama*.dylib' \
  --exclude='web-ui-app/libmtmd*.dylib' \
  --exclude='web-ui-app/web-ui-app' \
  --exclude='gost-local-proxy/gost-local-proxy' \
  "$ROOT/ai" "$BUNDLED_ROOT/"
cp "$WEB_UI_BIN" "$BUNDLED_ROOT/ai/web-ui-app/web-ui-app"
cp "$GOST_BIN" "$BUNDLED_ROOT/ai/gost-local-proxy/gost-local-proxy"
if [ -n "$SCALING_PACKAGE_DIR" ]; then
  mkdir -p "$BUNDLED_ROOT/Resources/Guest/scaling-app/package"
  rsync -a --delete "$SCALING_PACKAGE_DIR/" "$BUNDLED_ROOT/Resources/Guest/scaling-app/package/"
fi
if [ -n "$PERFORMANCE_PACKAGE_DIR" ]; then
  mkdir -p "$BUNDLED_ROOT/Resources/Guest/performance-app/package"
  rsync -a --delete "$PERFORMANCE_PACKAGE_DIR/" "$BUNDLED_ROOT/Resources/Guest/performance-app/package/"
fi
if [ -n "$BOOTSTRAP_LLAMA_RUNTIME_DIR" ]; then
  if [ ! -f "$BOOTSTRAP_LLAMA_RUNTIME_DIR/llama-runtime-manifest.json" ]; then
    printf 'Missing bundled llama.cpp runtime manifest: %s\n' "$BOOTSTRAP_LLAMA_RUNTIME_DIR/llama-runtime-manifest.json" >&2
    exit 1
  fi
  mkdir -p "$BUNDLED_ROOT/ai/bootstrap-runtimes/llama"
  rsync -a --delete "$BOOTSTRAP_LLAMA_RUNTIME_DIR/" "$BUNDLED_ROOT/ai/bootstrap-runtimes/llama/"
fi
rsync -a "$ROOT/docs" "$BUNDLED_ROOT/" 2>/dev/null || true
rsync -a "$ROOT/legal" "$BUNDLED_ROOT/" 2>/dev/null || true
mkdir -p "$BUNDLED_ROOT/legal/generated"
rsync -a "$LEGAL_BUILD_DIR/" "$BUNDLED_ROOT/legal/generated/"
cp "$LOCAL_PROXY_BIN" "$BUNDLED_ROOT/tools/bin/pegpu-local-proxy"
cp "$AUDIO_HOST_BIN" "$BUNDLED_ROOT/tools/bin/pegpu-audio-host"
if [ -f "$ROOT/Resources/Assets/PEGPU.icns" ]; then
  cp "$ROOT/Resources/Assets/PEGPU.icns" "$RESOURCES/PEGPU.icns"
fi

script_mismatches=()
for rel in \
  "Resources/Guest/pegpu-firstboot.sh" \
  "Resources/Guest/customization.sh" \
  "Resources/Guest/reconcile-llama-runtimes.sh" \
  "Resources/Guest/pegpu-gui-ensure.sh" \
  "Resources/Guest/pegpu-agent.sh"
do
  if ! cmp -s "$ROOT/$rel" "$BUNDLED_ROOT/$rel"; then
    script_mismatches+=("$rel")
  fi
done
if [ "${#script_mismatches[@]}" -gt 0 ]; then
  printf 'Refusing bundle with stale guest scripts:\\n' >&2
  printf '%s\\n' "${script_mismatches[@]}" >&2
  exit 1
fi

forbidden_machine_refs="$(
  find "$BUNDLED_ROOT" \
    \( \
      \( -type f \( \
        -name 'qemu-vfio-apple' -o \
        -name 'qemu-system-aarch64' -o \
        -name 'qemu-img' -o \
        -name 'edk2-*.fd' -o \
        -name 'QEMU_EFI*' \
      \) \) -o \
      \( -type d \( \
        -path "$BUNDLED_ROOT/share/qemu" -o \
        -path "$BUNDLED_ROOT/qemu" -o \
        -path "$BUNDLED_ROOT/guest-tools" \
      \) \) \
    \) \
    -print
)"
if [ -n "$forbidden_machine_refs" ]; then
  printf 'Refusing bundle with PEGPU Machine/QEMU artifacts in Apache-side app:\\n%s\\n' "$forbidden_machine_refs" >&2
  exit 1
fi

forbidden_llama_runtime_refs="$(
  find "$BUNDLED_ROOT" \
    -path "$BUNDLED_ROOT/ai/bootstrap-runtimes/llama" -prune -o \
    \( \
      -name 'pegpu-llama-runtime_*.deb' -o \
      -name '*llama*.dmg' -o \
      -name '*llama*.tar.gz' -o \
      -name 'llama-server' -o \
      -name 'rpc-server' -o \
      -name 'libggml*.dylib' -o \
      -name 'libllama*.dylib' -o \
      -name 'libmtmd*.dylib' \
    \) \
    -print
)"
if [ -n "$forbidden_llama_runtime_refs" ]; then
  printf 'Refusing bundle with stray llama.cpp runtime artifacts outside the controlled bootstrap runtime directory:\\n%s\\n' "$forbidden_llama_runtime_refs" >&2
  exit 1
fi

if [ -d "$DISPLAY_FRAMEWORKS" ]; then
  rsync -a --delete --include='*.framework/***' --include='*.framework' --exclude='*' "$DISPLAY_FRAMEWORKS/" "$FRAMEWORKS/"
  # The display artifact carries build, test, and gettext tool libraries. PEGPU.app ships only the runtime closure it loads.
  for framework in "${APP_EXCLUDED_DISPLAY_FRAMEWORKS[@]}"; do
    rm -rf "$FRAMEWORKS/$framework.framework"
  done
  "$ROOT/scripts/normalize-display-frameworks.sh" "$FRAMEWORKS"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>PEGPU</string>
  <key>CFBundleExecutable</key>
  <string>PEGPU</string>
  <key>CFBundleIconFile</key>
  <string>PEGPU</string>
  <key>CFBundleIdentifier</key>
  <string>com.pegpu.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>PEGPU</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MACOS_DEPLOYMENT_TARGET</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>PEGPU can forward the selected Mac microphone to the Linux VM when microphone audio is enabled.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>PEGPU uses Local Network access for the private connection between this Mac and the Linux VM, including SSH control, web UI and proxy routes, runtime RPC, file sharing, and guest setup.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_pegpu-preflight._tcp</string>
    <string>_ssh._tcp</string>
    <string>_http._tcp</string>
  </array>
</dict>
</plist>
PLIST

if [ -x "$BUNDLED_ROOT/tools/bin/pegpu-audio-host" ]; then
  codesign --force --sign - "$BUNDLED_ROOT/tools/bin/pegpu-audio-host" >/dev/null
fi

if [ -d "$FRAMEWORKS" ]; then
  while IFS= read -r framework; do
    codesign --force --sign - "$framework" >/dev/null
  done < <(find "$FRAMEWORKS" -maxdepth 1 -type d -name '*.framework' | sort)
  "$ROOT/scripts/normalize-display-frameworks.sh" --check "$FRAMEWORKS"
fi
for framework in "${ANGLE_REQUIRED_FRAMEWORKS[@]}"; do
  if [ ! -d "$FRAMEWORKS/$framework.framework" ]; then
    printf 'Refusing bundle without app-side ANGLE runtime: %s.framework\n' "$framework" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$FRAMEWORKS/$framework.framework" >/dev/null
done

if command -v otool >/dev/null 2>&1; then
  otool_targets=()
  while IFS= read -r binary; do
    otool_targets+=("$binary")
  done < <(python3 - "$MACOS" "$FRAMEWORKS" "$BUNDLED_ROOT/tools/bin" <<'PY'
from pathlib import Path
import os
import sys

roots = [Path(arg) for arg in sys.argv[1:]]
mach_o_magics = {
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xd0\x0d",
}
seen = set()
for root in roots:
    if not root.exists():
        continue
    candidates = [root] if root.is_file() else sorted(path for path in root.rglob("*") if path.is_file())
    for path in candidates:
        try:
            real = os.path.realpath(path)
            if real in seen:
                continue
            with path.open("rb") as handle:
                magic = handle.read(4)
        except OSError:
            continue
        if magic in mach_o_magics:
            seen.add(real)
            print(path)
PY
  )
  if [ "${#otool_targets[@]}" -eq 0 ]; then
    printf 'Refusing bundle with no Mach-O executables or framework binaries to validate.\n' >&2
    exit 1
  fi
  bad_refs="$(otool -L "${otool_targets[@]}" | grep -E '/Applications/UTM\\.app|/opt/homebrew|/usr/local/Cellar' || true)"
  if [ -n "$bad_refs" ]; then
    printf 'Refusing bundle with non-standalone display references:\\n%s\\n' "$bad_refs" >&2
    exit 1
  fi
  missing_refs="$(
    python3 - "$FRAMEWORKS" "${otool_targets[@]}" <<'PY'
import os
import re
import subprocess
import sys

frameworks = sys.argv[1]
targets = sys.argv[2:]
provided = {
    name.removesuffix(".framework")
    for name in os.listdir(frameworks)
    if name.endswith(".framework")
}
needed = set()
for target in targets:
    output = subprocess.run(["otool", "-L", target], text=True, capture_output=True, check=True).stdout
    for line in output.splitlines()[1:]:
        dep = line.strip().split(" ", 1)[0]
        match = re.match(r"@rpath/([^/]+)\.framework/", dep)
        if match:
            needed.add(match.group(1))
missing = sorted(needed - provided)
for item in missing:
    print(item)
PY
  )"
  if [ -n "$missing_refs" ]; then
    printf 'Refusing bundle with missing @rpath frameworks:\\n%s\\n' "$missing_refs" >&2
    exit 1
  fi
fi

codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"

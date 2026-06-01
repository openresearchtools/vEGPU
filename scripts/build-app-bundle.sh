#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION="${VERSION:-${RELEASE_VERSION:-0.1.0}}"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vegpu-build"
BUILD_ROOT="${VEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
APP_BUILD_DIR="${VEGPU_APP_BUILD_DIR:-$BUILD_ROOT/app-build}"
SWIFT_BUILD_SCRATCH_PATH="${SWIFT_BUILD_SCRATCH_PATH:-$BUILD_ROOT/swiftpm-$CONFIGURATION}"
APP="${VEGPU_APP:-$BUILD_ROOT/vEGPU.app}"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
BUNDLED_ROOT="$RESOURCES/vEGPURoot"
DISPLAY_FRAMEWORKS="${VEGPU_DISPLAY_FRAMEWORKS_OUT:-$BUILD_ROOT/display-frameworks/macos-arm64}"
ANGLE_NOTICE_DIR="${VEGPU_ANGLE_NOTICE_DIR:-$ROOT/third_party/angle}"
LEGAL_BUILD_DIR="${VEGPU_LEGAL_BUILD_DIR:-$BUILD_ROOT/legal/generated}"
SCALING_PACKAGE_DIR="${VEGPU_SCALING_PACKAGE_DIR:-}"
WEB_UI_BIN="$APP_BUILD_DIR/web-ui-app"
GOST_BIN="$APP_BUILD_DIR/gost-local-proxy"
AUDIO_HOST_BIN="$APP_BUILD_DIR/tools/bin/vegpu-audio-host"
LOCAL_PROXY_BIN="$APP_BUILD_DIR/tools/bin/vegpu-local-proxy"
ANGLE_REQUIRED_FRAMEWORKS=(EGL GLESv2)

cd "$ROOT"

missing_angle_frameworks=()
for framework in "${ANGLE_REQUIRED_FRAMEWORKS[@]}"; do
  if [ ! -d "$DISPLAY_FRAMEWORKS/$framework.framework" ]; then
    missing_angle_frameworks+=("$framework.framework")
  fi
done
if [ "${#missing_angle_frameworks[@]}" -gt 0 ]; then
  printf 'Missing app-side display framework(s): %s\n' "${missing_angle_frameworks[*]}" >&2
  printf 'Build or download the vEGPU-display-frameworks-macos-arm64 artifact and set VEGPU_DISPLAY_FRAMEWORKS_OUT.\n' >&2
  exit 1
fi
for notice in SOURCE.md ANGLE.plist LICENSE; do
  if [ ! -f "$ANGLE_NOTICE_DIR/$notice" ]; then
    printf 'Missing app-side ANGLE notice metadata: %s\n' "$ANGLE_NOTICE_DIR/$notice" >&2
    exit 1
  fi
done

mkdir -p "$APP_BUILD_DIR/tools/bin"
export VEGPU_BUILD_ROOT="$BUILD_ROOT"
export VEGPU_DISPLAY_FRAMEWORKS_OUT="$DISPLAY_FRAMEWORKS"
export VEGPU_UTM_PATCHED_WORKTREE="${VEGPU_UTM_PATCHED_WORKTREE:-$BUILD_ROOT/utm-patched}"
export VEGPU_COCOASPICE_PACKAGE_PATH="${VEGPU_COCOASPICE_PACKAGE_PATH:-$VEGPU_UTM_PATCHED_WORKTREE/OpenResearchTools/CocoaSpice}"
"$ROOT/scripts/apply-utm-patches.sh" >/dev/null
swift build --configuration "$CONFIGURATION" --disable-sandbox --scratch-path "$SWIFT_BUILD_SCRATCH_PATH"
SWIFT_BUILD_DIR="$(cd "$SWIFT_BUILD_SCRATCH_PATH/$CONFIGURATION" && pwd -P)"

(cd "$ROOT/ai/web-ui-app" && go build -o "$WEB_UI_BIN" .)
(cd "$ROOT/ai/gost-local-proxy" && go build -o "$GOST_BIN" .)
SDKROOT="$(xcrun --show-sdk-path)"
"$(xcrun --find clang)" -isysroot "$SDKROOT" -O2 -Wall -Wextra \
  -framework AudioToolbox -framework CoreAudio \
  -o "$AUDIO_HOST_BIN" \
  "$ROOT/Helpers/AudioBridge/vegpu-audio-host.c"
cp "$GOST_BIN" "$LOCAL_PROXY_BIN"
chmod +x "$WEB_UI_BIN" "$GOST_BIN" "$LOCAL_PROXY_BIN" "$AUDIO_HOST_BIN"
"$ROOT/scripts/build-legal-bundle.sh" "$LEGAL_BUILD_DIR" >/dev/null

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS" "$BUNDLED_ROOT/tools/bin"

cp "$SWIFT_BUILD_DIR/vEGPUApp" "$MACOS/vEGPUApp"
cp "$SWIFT_BUILD_DIR/vegpu" "$BUNDLED_ROOT/tools/bin/vegpu"
chmod +x "$MACOS/vEGPUApp" "$BUNDLED_ROOT/tools/bin/vegpu"
while IFS= read -r bundle; do
  rm -rf "$RESOURCES/$(basename "$bundle")"
  /usr/bin/ditto "$bundle" "$RESOURCES/$(basename "$bundle")"
done < <(find "$SWIFT_BUILD_DIR" -maxdepth 1 -type d -name '*.bundle' | sort)

cp "$ROOT/Package.swift" "$BUNDLED_ROOT/Package.swift"
rsync -a \
  --exclude='Guest/scaling-app/build/***' \
  --exclude='Guest/scaling-app/**/__pycache__/***' \
  --exclude='Guest/scaling-app/**/*.pyc' \
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
rsync -a "$ROOT/docs" "$BUNDLED_ROOT/" 2>/dev/null || true
rsync -a "$ROOT/legal" "$BUNDLED_ROOT/" 2>/dev/null || true
mkdir -p "$BUNDLED_ROOT/legal/generated"
rsync -a "$LEGAL_BUILD_DIR/" "$BUNDLED_ROOT/legal/generated/"
cp "$LOCAL_PROXY_BIN" "$BUNDLED_ROOT/tools/bin/vegpu-local-proxy"
cp "$AUDIO_HOST_BIN" "$BUNDLED_ROOT/tools/bin/vegpu-audio-host"
if [ -f "$ROOT/Resources/Assets/vEGPU.icns" ]; then
  cp "$ROOT/Resources/Assets/vEGPU.icns" "$RESOURCES/vEGPU.icns"
fi

script_mismatches=()
for rel in \
  "Resources/Guest/firstboot.sh" \
  "Resources/Guest/customization.sh" \
  "Resources/Guest/gui-ensure.sh" \
  "Resources/Guest/vegpu-agent.sh"
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
  printf 'Refusing bundle with vEGPU Machine/QEMU artifacts in Apache-side app:\\n%s\\n' "$forbidden_machine_refs" >&2
  exit 1
fi

forbidden_llama_runtime_refs="$(
  find "$BUNDLED_ROOT" \
    \( \
      -name 'vegpu-llama-runtime_*.deb' -o \
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
  printf 'Refusing bundle with bundled llama.cpp runtime artifacts; install runtimes through Core releases:\\n%s\\n' "$forbidden_llama_runtime_refs" >&2
  exit 1
fi

if [ -d "$DISPLAY_FRAMEWORKS" ]; then
  rsync -a --delete --include='*.framework/***' --include='*.framework' --exclude='*' "$DISPLAY_FRAMEWORKS/" "$FRAMEWORKS/"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>vEGPU</string>
  <key>CFBundleExecutable</key>
  <string>vEGPUApp</string>
  <key>CFBundleIconFile</key>
  <string>vEGPU</string>
  <key>CFBundleIdentifier</key>
  <string>com.vegpu.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>vEGPU</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>vEGPU can forward the selected Mac microphone to the Linux VM when microphone audio is enabled.</string>
</dict>
</plist>
PLIST

if [ -x "$BUNDLED_ROOT/tools/bin/vegpu-audio-host" ]; then
  codesign --force --sign - "$BUNDLED_ROOT/tools/bin/vegpu-audio-host" >/dev/null
fi

if [ -d "$FRAMEWORKS" ]; then
  while IFS= read -r framework; do
    codesign --force --sign - "$framework" >/dev/null
  done < <(find "$FRAMEWORKS" -maxdepth 1 -type d -name '*.framework' | sort)
fi
for framework in "${ANGLE_REQUIRED_FRAMEWORKS[@]}"; do
  if [ ! -d "$FRAMEWORKS/$framework.framework" ]; then
    printf 'Refusing bundle without app-side ANGLE runtime: %s.framework\n' "$framework" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$FRAMEWORKS/$framework.framework" >/dev/null
done

if command -v otool >/dev/null 2>&1; then
  otool_targets=("$MACOS/vEGPUApp")
  while IFS= read -r framework; do
    binary="$framework/$(basename "$framework" .framework)"
    [ -e "$binary" ] && otool_targets+=("$binary")
  done < <(find "$FRAMEWORKS" -maxdepth 1 -type d -name '*.framework' | sort)
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

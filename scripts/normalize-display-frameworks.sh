#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vegpu-build"
BUILD_ROOT="${VEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
FRAMEWORKS_DIR="${1:-${VEGPU_DISPLAY_FRAMEWORKS_OUT:-$BUILD_ROOT/display-frameworks/macos-arm64}}"

set_bundle_id() {
  local framework="$1"
  local bundle_id="$2"
  local info="$FRAMEWORKS_DIR/$framework.framework/Versions/A/Resources/Info.plist"
  if [ ! -f "$info" ]; then
    printf 'Missing Info.plist for %s.framework: %s\n' "$framework" "$info" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$info" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$info"
}

set_bundle_id EGL com.vegpu.app.angle.EGL
set_bundle_id GLESv2 com.vegpu.app.angle.GLESv2

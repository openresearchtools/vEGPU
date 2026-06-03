#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vegpu-build"
BUILD_ROOT="${VEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
FRAMEWORKS_DIR="${1:-${VEGPU_DISPLAY_FRAMEWORKS_OUT:-$BUILD_ROOT/display-frameworks/macos-arm64}}"

plist_set_or_add() {
  local info="$1"
  local key="$2"
  local type="$3"
  local value="$4"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$info" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$info" >/dev/null
}

sanitize_bundle_component() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

framework_bundle_id() {
  local name="$1"
  case "$name" in
    EGL) printf 'com.vegpu.app.angle.EGL' ;;
    GLESv2) printf 'com.vegpu.app.angle.GLESv2' ;;
    *) printf 'com.vegpu.app.display.%s' "$(sanitize_bundle_component "$name")" ;;
  esac
}

normalize_install_name() {
  local framework="$1"
  local name="$2"
  local binary=""

  case "$name" in
    EGL|GLESv2) ;;
    *) return 0 ;;
  esac

  if [ -f "$framework/Versions/A/$name" ]; then
    binary="$framework/Versions/A/$name"
  elif [ -f "$framework/$name" ]; then
    binary="$framework/$name"
  fi

  if [ -n "$binary" ] && command -v install_name_tool >/dev/null 2>&1; then
    install_name_tool -id "@rpath/$name.framework/Versions/A/$name" "$binary"
  fi
}

normalize_framework() {
  local framework="$1"
  local name
  name="$(basename "$framework" .framework)"

  if [ ! -e "$framework/$name" ] && [ ! -e "$framework/Versions/A/$name" ]; then
    printf 'Missing framework executable for %s.framework\n' "$name" >&2
    exit 1
  fi

  if [ -d "$framework/Versions/A" ]; then
    rm -rf "$framework/Versions/Current"
    (cd "$framework/Versions" && ln -s A Current)

    local item
    for item in "$name" Resources Headers PrivateHeaders Modules; do
      if [ -e "$framework/Versions/A/$item" ]; then
        rm -rf "$framework/$item"
        (cd "$framework" && ln -s "Versions/Current/$item" "$item")
      fi
    done
  fi

  normalize_install_name "$framework" "$name"

  local infos=()
  while IFS= read -r info; do
    infos+=("$info")
  done < <(find "$framework" -path '*/Resources/Info.plist' -type f | sort)

  if [ "${#infos[@]}" -eq 0 ]; then
    mkdir -p "$framework/Versions/A/Resources"
    cat > "$framework/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
    infos=("$framework/Versions/A/Resources/Info.plist")
  fi

  local bundle_id
  bundle_id="$(framework_bundle_id "$name")"
  local info
  for info in "${infos[@]}"; do
    plist_set_or_add "$info" CFBundlePackageType string FMWK
    plist_set_or_add "$info" CFBundleExecutable string "$name"
    plist_set_or_add "$info" CFBundleIdentifier string "$bundle_id"
    plist_set_or_add "$info" CFBundleName string "$name"
    plist_set_or_add "$info" CFBundleVersion string 1
    plist_set_or_add "$info" CFBundleShortVersionString string 1.0
  done
}

if [ ! -d "$FRAMEWORKS_DIR" ]; then
  printf 'Display frameworks directory does not exist: %s\n' "$FRAMEWORKS_DIR" >&2
  exit 1
fi

while IFS= read -r framework; do
  normalize_framework "$framework"
done < <(find "$FRAMEWORKS_DIR" -maxdepth 1 -type d -name '*.framework' | sort)

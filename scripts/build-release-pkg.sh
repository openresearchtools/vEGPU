#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pegpu-build"
BUILD_ROOT="${PEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
VERSION="${VERSION:-0.1.0}"
PACKAGE_CHANNEL="${PEGPU_PACKAGE_CHANNEL:-release}"
APP="${PEGPU_APP:-$BUILD_ROOT/PEGPU.app}"
MACHINE_APP="${PEGPU_MACHINE_APP:-/Applications/PEGPU Machine.app}"
REQUIRE_MACHINE_APP="${PEGPU_REQUIRE_MACHINE_APP:-1}"
REQUIRE_MACHINE_SOURCE="${PEGPU_REQUIRE_MACHINE_SOURCE:-0}"
case "$PACKAGE_CHANNEL" in
  release) DEFAULT_PKG_NAME="PEGPU-v$VERSION.pkg" ;;
  pre-release) DEFAULT_PKG_NAME="PEGPU-v$VERSION.pkg" ;;
  artifact) DEFAULT_PKG_NAME="PEGPU-v$VERSION.pkg" ;;
  *) DEFAULT_PKG_NAME="PEGPU-v$VERSION-$PACKAGE_CHANNEL.pkg" ;;
esac
OUT="${OUT:-$BUILD_ROOT/$DEFAULT_PKG_NAME}"
WORK="${PEGPU_PKG_BUILD_DIR:-$BUILD_ROOT/pkg}"
COMPONENTS="$WORK/components"
RESOURCES="$WORK/resources"
SCRIPTS_APP="$WORK/scripts-app"
SCRIPTS_MACHINE="$WORK/scripts-machine"
SCRIPTS_DRIVER="$WORK/scripts-driver"
STAGE_APP="$WORK/stage-app"
STAGE_MACHINE="$WORK/stage-machine"
INCLUDE_MACHINE=0
MACHINE_NEW_BUILD=""
MACHINE_NEW_SHORT_VERSION=""

if [ ! -d "$APP" ]; then
  CONFIGURATION="${CONFIGURATION:-release}" "$ROOT/scripts/build-app-bundle.sh" >/dev/null
fi
if [ ! -d "$APP" ]; then
  printf 'Missing PEGPU.app: %s\n' "$APP" >&2
  exit 1
fi
if [ ! -d "$MACHINE_APP" ]; then
  if [ "$REQUIRE_MACHINE_APP" = "1" ]; then
    printf 'Missing PEGPU Machine.app: %s\n' "$MACHINE_APP" >&2
    printf 'Set PEGPU_MACHINE_APP to the built Machine app before packaging, or set PEGPU_REQUIRE_MACHINE_APP=0 for an app-only artifact package.\n' >&2
    exit 1
  fi
else
  INCLUDE_MACHINE=1
fi

rm -rf "$WORK"
mkdir -p "$COMPONENTS" "$RESOURCES" "$SCRIPTS_APP" "$SCRIPTS_MACHINE" "$SCRIPTS_DRIVER" "$STAGE_APP/Applications" "$STAGE_MACHINE/Applications"

/usr/bin/ditto "$APP" "$STAGE_APP/Applications/PEGPU.app"
if [ "$INCLUDE_MACHINE" = "1" ]; then
  /usr/bin/ditto "$MACHINE_APP" "$STAGE_MACHINE/Applications/PEGPU Machine.app"
  MACHINE_INFO="$STAGE_MACHINE/Applications/PEGPU Machine.app/Contents/Info.plist"
  MACHINE_NEW_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MACHINE_INFO" 2>/dev/null || true)"
  MACHINE_NEW_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MACHINE_INFO" 2>/dev/null || true)"
  MACHINE_ENTITLEMENTS="$WORK/machine-host.entitlements.plist"
  if ! /usr/bin/codesign -d --entitlements :- "$MACHINE_APP" >"$MACHINE_ENTITLEMENTS" 2>/dev/null; then
    /usr/bin/codesign -d --entitlements :- "$MACHINE_APP/Contents/MacOS/PEGPU Machine" >"$MACHINE_ENTITLEMENTS" 2>/dev/null || {
      printf 'Unable to read PEGPU Machine host app entitlements from: %s\n' "$MACHINE_APP" >&2
      exit 1
    }
  fi
  if ! /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.system-extension.install' "$MACHINE_ENTITLEMENTS" 2>/dev/null | /usr/bin/grep -qx 'true'; then
    printf 'PEGPU Machine host app is missing required entitlement: com.apple.developer.system-extension.install\n' >&2
    printf 'Machine app: %s\n' "$MACHINE_APP" >&2
    exit 1
  fi
  MACHINE_SOURCE_DEST="$STAGE_MACHINE/Applications/PEGPU Machine.app/Contents/Resources/SourceBundles"
  mkdir -p "$MACHINE_SOURCE_DEST"
  machine_source_count=0
  while IFS= read -r source_tar; do
    cp "$source_tar" "$MACHINE_SOURCE_DEST/"
    machine_source_count=$((machine_source_count + 1))
  done < <(find "$(dirname "$MACHINE_APP")" -maxdepth 1 -type f \( -name '*source*.tar.gz' -o -name '*source*.tar.xz' -o -name '*source*.tgz' \) | sort)
  if [ "$REQUIRE_MACHINE_SOURCE" = "1" ] && [ "$machine_source_count" -eq 0 ]; then
    printf 'Missing PEGPU Machine source tarball next to Machine app: %s\n' "$(dirname "$MACHINE_APP")" >&2
    exit 1
  fi
  /usr/bin/codesign --force --sign - --entitlements "$MACHINE_ENTITLEMENTS" "$STAGE_MACHINE/Applications/PEGPU Machine.app" >/dev/null
fi

APP_LEGAL="$STAGE_APP/Applications/PEGPU.app/Contents/Resources/PEGPURoot/legal/generated"
test -f "$APP_LEGAL/NOTICES"
test -f "$APP_LEGAL/LICENSES"
test -f "$APP_LEGAL/GUEST-VM-INSTALL-NOTICES.md"
test -f "$APP_LEGAL/source/PEGPU-app-source.tar.gz"
test -f "$APP_LEGAL/source/display-runtime-source.tar.gz"
test -f "$APP_LEGAL/source/PEGPU-app-source.NOTICES"
test -f "$APP_LEGAL/source/PEGPU-app-source.LICENSES"
test -f "$APP_LEGAL/source/PEGPU-app-source.manifest.json"
test -f "$APP_LEGAL/source/display-runtime-source.NOTICES"
test -f "$APP_LEGAL/source/display-runtime-source.LICENSES"
test -f "$APP_LEGAL/source/display-runtime-source.manifest.json"
test -d "$APP_LEGAL/license-files/display-runtime"
test -d "$APP_LEGAL/license-files/llama-runtime"
test "$(find "$APP_LEGAL/license-files/display-runtime" -type f | wc -l | tr -d ' ')" -ge 20
test "$(find "$APP_LEGAL/license-files/llama-runtime" -type f | wc -l | tr -d ' ')" -ge 3
grep -F 'Package/Dependency: Display runtime: glib' "$APP_LEGAL/LICENSES" >/dev/null
grep -F 'Package/Dependency: Display runtime: openssl' "$APP_LEGAL/LICENSES" >/dev/null
grep -F 'Package/Dependency: Bundled llama.cpp runtime' "$APP_LEGAL/LICENSES" >/dev/null
grep -F 'Package/Dependency: llama-swap routing provenance' "$APP_LEGAL/LICENSES" >/dev/null
grep -F 'Package/Dependency: llama.cpp' "$APP_LEGAL/LICENSES" >/dev/null
grep -F 'Package/Dependency: GOST/local proxy provenance' "$APP_LEGAL/LICENSES" >/dev/null
grep -F 'Package/Dependency: AI web UI/router provenance' "$APP_LEGAL/LICENSES" >/dev/null
grep -F 'Package/Dependency: Go module: web-ui-app' "$APP_LEGAL/LICENSES" >/dev/null
grep -F 'Package/Dependency: Go module: gopkg.in/yaml.v3' "$APP_LEGAL/LICENSES" >/dev/null
grep -F 'Package/Dependency: SwiftPM: swiftterm' "$APP_LEGAL/LICENSES" >/dev/null
grep -F 'Package/Dependency: SwiftPM: swift-argument-parser' "$APP_LEGAL/LICENSES" >/dev/null
grep -F 'Component-Scope: Swift package used by PEGPU.app' "$APP_LEGAL/LICENSES" >/dev/null
awk 'BEGIN{found=0; in_angle=0} /^Package\/Dependency: ANGLE$/ {in_angle=1} in_angle && /^License:/ {if ($0 == "License: BSD-3-Clause") found=1; in_angle=0} END{exit found ? 0 : 1}' "$APP_LEGAL/LICENSES"
grep -F 'For convenience, PEGPU.app Help can render external PEGPU Machine notices and licenses' "$APP_LEGAL/NOTICES" >/dev/null
grep -F 'The Help menu marks those Machine-owned rows as EXTERNAL' "$APP_LEGAL/NOTICES" >/dev/null
grep -F 'visible architecture, repository, license, notice, and source boundary' "$APP_LEGAL/NOTICES" >/dev/null
grep -F 'PEGPU uses a stricter form of the UTM / UTM-QEMU-style architecture' "$APP_LEGAL/NOTICES" >/dev/null
grep -F 'The app-visible LICENSES file is the consolidated license record for the installed PEGPU.app application/runtime distribution' "$APP_LEGAL/NOTICES" >/dev/null
grep -F 'The legal records for those source archive contents are generated next to each archive' "$APP_LEGAL/NOTICES" >/dev/null
grep -F 'Machine/QEMU license text is not copied into this PEGPU.app LICENSES file' "$APP_LEGAL/LICENSES" >/dev/null
if awk '/^License:/ && $0 ~ /(GPL|AGPL)/ && $0 !~ /LGPL/ {print; bad=1} END {exit bad ? 0 : 1}' "$APP_LEGAL/LICENSES"; then
  printf 'PEGPU.app runtime/distribution LICENSES must not contain GPL-only dependency blocks\n' >&2
  exit 1
fi
if grep -E 'The following are distributed under GPL v2|gst-plugins-base-1[.]15[.]2[.]tar[.]xz|qemu-4[.]2[.]0[.]tar[.]xz' "$APP_LEGAL/LICENSES"; then
  printf 'PEGPU.app LICENSES must not include UTM aggregate app license text; use UTM Apache license/provenance instead\n' >&2
  exit 1
fi
if grep -E 'The following are distributed under GPL v2|gst-plugins-base-1[.]15[.]2[.]tar[.]xz|qemu-4[.]2[.]0[.]tar[.]xz' "$APP_LEGAL/source/"*.LICENSES; then
  printf 'PEGPU.app source sidecar licenses must not include UTM aggregate app license text; use source-specific licenses/provenance instead\n' >&2
  exit 1
fi
if find "$APP_LEGAL/license-files" -type f | awk '{ lower=tolower($0); if ((lower ~ /agpl/ || lower ~ /gpl/) && lower !~ /lgpl/) { print; bad=1 } } END { exit bad ? 0 : 1 }'; then
  printf 'PEGPU.app legal payload must not copy GPL/AGPL-only source license files into app-visible license-files\n' >&2
  exit 1
fi
if grep -E 'archives scanned|license/notice files harvested|license/notice files collected|Included License/Notice Files|Swift Package Pins|Go Modules|Bundle identifier' "$APP_LEGAL/NOTICES"; then
  printf 'PEGPU.app NOTICES must be user-facing packaging/legal prose, not a raw generated audit inventory\n' >&2
  exit 1
fi
if grep -E '^- PEGPU Machine .*[(]missing[)]' "$APP_LEGAL/NOTICES"; then
  printf 'PEGPU.app NOTICES must not describe external Machine legal paths with build-time missing status\n' >&2
  exit 1
fi
if grep -E 'archives scanned|license/notice files harvested|license/notice files collected|Included License/Notice Files|Swift Package Pins|Go Modules|Bundle identifier|records found' "$APP_LEGAL/source/"*.NOTICES; then
  printf 'source archive NOTICES sidecars must be user-facing legal/source prose, not raw generated audit inventories\n' >&2
  exit 1
fi

write_install_scripts() {
  local dir="$1"
  local scope="${2:-app}"
  local machine_new_build="${3:-}"
  local machine_new_short_version="${4:-}"
  mkdir -p "$dir"
  cat > "$dir/preinstall" <<'SCRIPT'
#!/bin/bash
set -e

status="$(/usr/bin/csrutil status 2>/dev/null || true)"
if ! printf '%s\n' "$status" | /usr/bin/grep -qi 'disabled'; then
  cat >&2 <<'TEXT'
PEGPU requires System Integrity Protection (SIP) to be disabled before installation.

To disable SIP on Apple Silicon:
1. Shut down the Mac.
2. Hold the power button until startup options appear.
3. Open Options, then Utilities, then Terminal.
4. Run: csrutil disable
5. Restart macOS and run this installer again.

This is required because PEGPU Machine installs and loads an ad-hoc DriverKit
host extension for PCIe/eGPU passthrough. Do not install PEGPU on a machine
that holds sensitive data unless you accept that security tradeoff.
TEXT
  exit 1
fi
SCRIPT

  if [ "$scope" = "driver" ]; then
    cat >> "$dir/preinstall" <<'SCRIPT'

PEGPU_INSTALLED_MACHINE="/Applications/PEGPU Machine.app"
PEGPU_MACHINE_EXECUTABLE="$PEGPU_INSTALLED_MACHINE/Contents/MacOS/PEGPU Machine"
PEGPU_DRIVER_ID="com.pegpu.machine.VFIOUserPCIDriver"
PEGPU_DRIVER_REFRESH_MARKER="/tmp/com.pegpu.machine.pkg.driver-refresh-needed"
PEGPU_DRIVER_LOG="/var/log/pegpu-driver-install.log"

rm -f "$PEGPU_DRIVER_REFRESH_MARKER"
mkdir -p "$(dirname "$PEGPU_DRIVER_LOG")"
touch "$PEGPU_DRIVER_LOG"
chmod 0644 "$PEGPU_DRIVER_LOG" 2>/dev/null || true
exec >>"$PEGPU_DRIVER_LOG" 2>&1
echo "---- PEGPU Machine preinstall driver refresh $(date -u '+%Y-%m-%dT%H:%M:%SZ') ----"

run_with_timeout() {
  local seconds="$1"
  shift
  "$@" &
  local pid=$!
  local elapsed=0
  while /bin/kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$seconds" ]; then
      echo "Command timed out after ${seconds}s: $*"
      /bin/kill "$pid" 2>/dev/null || true
      /bin/sleep 2
      /bin/kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    /bin/sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid"
}

run_as_console_user_with_timeout() {
  local seconds="$1"
  shift
  local console_user console_uid
  console_user="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)"
  if [ -z "$console_user" ] || [ "$console_user" = "root" ]; then
    run_with_timeout "$seconds" "$@"
    return $?
  fi
  console_uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
  if [ -z "$console_uid" ]; then
    run_with_timeout "$seconds" "$@"
    return $?
  fi
  run_with_timeout "$seconds" /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" "$@"
}

driver_installed() {
  /usr/bin/systemextensionsctl list 2>/dev/null | /usr/bin/grep -Fq "$PEGPU_DRIVER_ID"
}

force_uninstall_driver() {
  /usr/bin/systemextensionsctl uninstall - "$PEGPU_DRIVER_ID"
}

touch "$PEGPU_DRIVER_REFRESH_MARKER"
echo "PEGPU DriverKit component selected. Preparing macOS DriverKit extension before activation."
if [ -x "$PEGPU_MACHINE_EXECUTABLE" ]; then
  echo "Existing PEGPU Machine app found. Asking it to deactivate the current driver."
  if run_as_console_user_with_timeout 20 "$PEGPU_MACHINE_EXECUTABLE" --driver-deactivate; then
    echo "Existing macOS driver deactivation request completed."
  else
    echo "Graceful macOS driver deactivation failed or timed out."
    if driver_installed; then
      echo "Driver extension is still listed; attempting forced system extension uninstall."
      force_uninstall_driver || echo "Forced macOS driver uninstall did not complete; continuing package replacement." >&2
    else
      echo "Driver extension is no longer listed; no forced uninstall needed."
    fi
  fi
else
  echo "Existing PEGPU Machine app is missing."
  if driver_installed; then
    echo "Driver extension is still listed without its owning app; attempting forced system extension uninstall."
    force_uninstall_driver || echo "Forced macOS driver uninstall did not complete; continuing package replacement." >&2
  else
    echo "No existing PEGPU DriverKit extension is listed; no preinstall driver removal needed."
  fi
fi
SCRIPT
  fi

  cat >> "$dir/preinstall" <<'SCRIPT'
exit 0
SCRIPT

  cat > "$dir/postinstall" <<'SCRIPT'
#!/bin/bash
set -e

clear_app_attrs() {
  local app="$1"
  [ -d "$app" ] || return 0

  /usr/bin/xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
  /usr/bin/xattr -cr "$app" 2>/dev/null || true
  /bin/chmod -R a+rX "$app" 2>/dev/null || true

  for dir in \
    "$app/Contents/MacOS" \
    "$app/Contents/Helpers" \
    "$app/Contents/Library/SystemExtensions"; do
    if [ -d "$dir" ]; then
      /usr/bin/find "$dir" -type f -exec /bin/chmod a+rx {} + 2>/dev/null || true
    fi
  done
}

clear_app_attrs "/Applications/PEGPU.app"
clear_app_attrs "/Applications/PEGPU Machine.app"
SCRIPT

  if [ "$scope" = "driver" ]; then
    cat >> "$dir/postinstall" <<'SCRIPT'

PEGPU_MACHINE_EXECUTABLE="/Applications/PEGPU Machine.app/Contents/MacOS/PEGPU Machine"
PEGPU_DRIVER_REFRESH_MARKER="/tmp/com.pegpu.machine.pkg.driver-refresh-needed"
PEGPU_DRIVER_LOG="/var/log/pegpu-driver-install.log"
PEGPU_DRIVER_ID="com.pegpu.machine.VFIOUserPCIDriver"
mkdir -p "$(dirname "$PEGPU_DRIVER_LOG")"
touch "$PEGPU_DRIVER_LOG"
chmod 0644 "$PEGPU_DRIVER_LOG" 2>/dev/null || true
exec >>"$PEGPU_DRIVER_LOG" 2>&1
echo "---- PEGPU Machine postinstall driver activation $(date -u '+%Y-%m-%dT%H:%M:%SZ') ----"

run_with_timeout() {
  local seconds="$1"
  shift
  "$@" &
  local pid=$!
  local elapsed=0
  while /bin/kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$seconds" ]; then
      echo "Command timed out after ${seconds}s: $*"
      /bin/kill "$pid" 2>/dev/null || true
      /bin/sleep 2
      /bin/kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    /bin/sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid"
}

run_as_console_user_with_timeout() {
  local seconds="$1"
  shift
  local console_user console_uid
  console_user="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)"
  if [ -z "$console_user" ] || [ "$console_user" = "root" ]; then
    run_with_timeout "$seconds" "$@"
    return $?
  fi
  console_uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
  if [ -z "$console_uid" ]; then
    run_with_timeout "$seconds" "$@"
    return $?
  fi
  run_with_timeout "$seconds" /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" "$@"
}

log_driver_status() {
  echo "Current macOS system extension state for $PEGPU_DRIVER_ID:"
  if /usr/bin/systemextensionsctl list 2>/dev/null | /usr/bin/grep -F "$PEGPU_DRIVER_ID"; then
    return 0
  fi
  echo "Driver extension is not listed yet."
}

if [ ! -f "$PEGPU_DRIVER_REFRESH_MARKER" ]; then
  echo "PEGPU Machine driver refresh was not requested; leaving existing driver state unchanged."
elif [ -x "$PEGPU_MACHINE_EXECUTABLE" ]; then
  echo "New PEGPU Machine app is installed. Asking it to activate the DriverKit extension."
  if run_as_console_user_with_timeout 45 "$PEGPU_MACHINE_EXECUTABLE" --driver-activate; then
    echo "PEGPU Machine macOS driver activation request submitted."
    log_driver_status || true
  else
    echo "PEGPU Machine macOS driver activation request failed. Open PEGPU Machine or PEGPU.app Runtime > Install Driver and retry after approving the extension in System Settings."
    log_driver_status || true
  fi
else
  echo "PEGPU Machine executable is missing after installation: $PEGPU_MACHINE_EXECUTABLE" >&2
  log_driver_status || true
fi
rm -f "$PEGPU_DRIVER_REFRESH_MARKER"
SCRIPT
  fi

  cat >> "$dir/postinstall" <<'SCRIPT'
exit 0
SCRIPT

  chmod 0755 "$dir/preinstall" "$dir/postinstall"
}

write_install_scripts "$SCRIPTS_APP" "app"
write_install_scripts "$SCRIPTS_MACHINE" "machine" "$MACHINE_NEW_BUILD" "$MACHINE_NEW_SHORT_VERSION"
write_install_scripts "$SCRIPTS_DRIVER" "driver" "$MACHINE_NEW_BUILD" "$MACHINE_NEW_SHORT_VERSION"

write_nonrelocatable_component_plist() {
  local stage_root="$1"
  local plist="$2"

  pkgbuild --analyze --root "$stage_root" "$plist" >/dev/null
  python3 - "$plist" <<'PY'
import plistlib
import sys

plist_path = sys.argv[1]
with open(plist_path, "rb") as handle:
    components = plistlib.load(handle)

def normalize(items):
    for item in items:
        item["BundleIsRelocatable"] = False
        item["BundleIsVersionChecked"] = False
        item["BundleHasStrictIdentifier"] = True
        item["BundleOverwriteAction"] = "upgrade"
        normalize(item.get("ChildBundles", []))

normalize(components)
with open(plist_path, "wb") as handle:
    plistlib.dump(components, handle, sort_keys=False)
PY
}

APP_COMPONENTS_PLIST="$WORK/PEGPU-app-components.plist"
MACHINE_COMPONENTS_PLIST="$WORK/PEGPU-machine-components.plist"
write_nonrelocatable_component_plist "$STAGE_APP" "$APP_COMPONENTS_PLIST"
if [ "$INCLUDE_MACHINE" = "1" ]; then
  write_nonrelocatable_component_plist "$STAGE_MACHINE" "$MACHINE_COMPONENTS_PLIST"
fi

if [ -f "$ROOT/Resources/Assets/PEGPU-logo-transparent.png" ]; then
  cp "$ROOT/Resources/Assets/PEGPU-logo-transparent.png" "$RESOURCES/PEGPU-logo-transparent.png"
fi

cat > "$RESOURCES/WELCOME.html" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font: -apple-system-body; color: #1f2328; margin: 0; padding: 18px; }
    .top { display: flex; align-items: center; gap: 14px; margin-bottom: 10px; }
    img { width: 54px; height: 54px; border-radius: 10px; }
    h1 { font: -apple-system-title1; margin: 0; }
    h2 { font: -apple-system-headline; margin: 14px 0 6px; }
    h3 { font: -apple-system-subheadline; margin: 12px 0 4px; }
    p, li { line-height: 1.32; }
    ul { margin: 8px 0 8px 20px; padding: 0; }
    .warn { border-left: 4px solid #d1242f; padding-left: 10px; margin: 10px 0; }
    .boundary { border-left: 4px solid #0969da; padding-left: 10px; margin: 10px 0; }
    .code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .footnote { color: #667085; font-size: 11px; margin-top: 12px; }
    .links { margin-top: 10px; }
  </style>
</head>
<body>
  <div class="top">
    <img src="PEGPU-logo-transparent.png" alt="">
    <div>
      <h1>PEGPU</h1>
      <p>NVIDIA* eGPU passthrough and AI runtime orchestration for Apple Silicon Macs.</p>
    </div>
  </div>
  <p class="footnote">* Compatibility and purpose labels only. PEGPU is not endorsed by, sponsored by, affiliated with, or encouraged by Apple, NVIDIA, Linux, Thunderbolt, QEMU, UTM, Debian, llama.cpp, llama-swap, GOST, TurboQuant, Scott J. Goldman, or any named company, protocol, project, or maintainer.</p>

  <h2>Important: SIP Must Be Disabled</h2>
  <p class="warn">System Integrity Protection must be disabled before installing PEGPU Machine's DriverKit passthrough component. There is no useful installation path with SIP enabled: this installer checks SIP before installation and will stop on a SIP-enabled Mac.</p>
  <p>PEGPU Machine uses an ad-hoc DriverKit system extension for PCIe/eGPU passthrough. Disabling SIP is a serious macOS security tradeoff.</p>
  <p>To disable SIP on Apple Silicon: shut down the Mac, hold the power button until Startup Options appear, open Options &gt; Utilities &gt; Terminal, run <span class="code">csrutil disable</span>, restart macOS, and run this installer again.</p>

  <h2>What This Installer Installs</h2>
  <p>This installer places two related applications in <strong>/Applications</strong> and keeps their license, source, and runtime boundary visible.</p>
  <h3>PEGPU.app</h3>
  <p>Apache-2.0 Swift/AppKit launcher and host-side application. It contains the UTM-derived embedded SPICE GUI display side, ANGLE/CocoaSpice integration, AI runtime controls, local routing helpers, app-side orchestration, notices, and app-side source/provenance archives.</p>
  <p>Repository: <a href="https://github.com/openresearchtools/PEGPU">https://github.com/openresearchtools/PEGPU</a></p>
  <h3>PEGPU Machine.app</h3>
  <p>Separate QEMU/VFIO/DriverKit virtual-machine runtime and macOS driver host. It contains the Machine-side passthrough mechanics, QEMU-derived GPL source bundles, firmware/runtime payloads, guest tools, guest-driver materials, DriverKit activation helpers, and Machine-side notices.</p>
  <p>Repository: <a href="https://github.com/openresearchtools/PEGPU-machine">https://github.com/openresearchtools/PEGPU-machine</a></p>

  <h2>Architecture and Source Boundary</h2>
  <p class="boundary">PEGPU uses a stricter form of the UTM / UTM-QEMU-style separation: the frontend, AI/runtime control surface, display client, routing, and orchestration live in PEGPU.app, while the GPL-covered Machine/QEMU VM runtime, VFIO, DriverKit, firmware, and guest-driver mechanics live in the separate PEGPU Machine.app.</p>
  <p>For convenience, PEGPU.app Help can render external PEGPU Machine notices and licenses from the installed PEGPU Machine.app. The Help menu marks those Machine-owned rows as EXTERNAL. PEGPU.app does not copy Machine legal text into its own bundle.</p>
  <p>The embedded display side is partially based on UTM app work. The Machine side builds on Scott J. Goldman's scottjg/qemu-vfio-apple as the main Apple VFIO/DriverKit/QEMU base, with additional QEMU-side visual-runtime work adapted from UTM QEMU and UTM virglrenderer.</p>

  <h2>Installation Behavior</h2>
  <p>The Installation Type screen shows install choices for PEGPU.app and PEGPU Machine.app. DriverKit extension refresh/activation is bundled under the Machine choice.</p>
  <p>For combined releases, PEGPU Machine.app is selected by default when it is missing or older than the installer payload. DriverKit refresh/activation follows the Machine.app choice and is not run when the Machine.app choice is not selected.</p>
  <p>If the installed PEGPU Machine app is the same or newer version and the DriverKit extension is already present, the Machine choice remains visible but is not selected by default.</p>
  <p>PEGPU Machine.app and its DriverKit refresh require SIP to be disabled. The installer checks SIP before installation and stops on SIP-enabled Macs.</p>
  <p>When DriverKit refresh/activation is selected, the installer attempts to ask the existing PEGPU Machine app to deactivate the old DriverKit extension when possible. Forced removal is used only when an old extension is still listed and graceful deactivation is unavailable or did not complete.</p>
  <p>The installer then asks the installed PEGPU Machine.app to submit a fresh DriverKit activation request and writes driver-install diagnostics to <span class="code">/var/log/pegpu-driver-install.log</span>.</p>
  <p>macOS may still require approval in System Settings and/or a restart before the driver becomes active. This installer does not bypass Apple's system-extension approval flow.</p>

  <h2>More Information</h2>
  <p class="links">Project website: <a href="https://pegpu.com">https://pegpu.com</a><br>Main app repository: <a href="https://github.com/openresearchtools/PEGPU">https://github.com/openresearchtools/PEGPU</a><br>Machine repository: <a href="https://github.com/openresearchtools/PEGPU-machine">https://github.com/openresearchtools/PEGPU-machine</a></p>
</body>
</html>
HTML

cat > "$RESOURCES/CONCLUSION.txt" <<'TEXT'
Finished.

If DriverKit extension refresh/activation was selected, the installer attempted
to deactivate the old macOS DriverKit extension and submit the new driver
activation request through the installed PEGPU Machine.app. macOS may still
require approval in System Settings.

Driver install log:
/var/log/pegpu-driver-install.log

If the Machine and DriverKit choice was selected, choose Restart to reboot now,
or quit Installer and reboot later. Restart before launching PEGPU with eGPUs
attached. If the driver still shows as pending after approval, open PEGPU.app
and use Runtime > Install Driver to retry the same PEGPU Machine helper path.

Open PEGPU.app Help for app notices, app licenses, VM install notices, and
external PEGPU Machine notices/licenses rendered from the installed
PEGPU Machine.app. Those legal files list the installed source archive
locations.
The Help menu marks Machine-owned legal rows as EXTERNAL.
TEXT

cat > "$RESOURCES/LICENSE.txt" <<'TEXT'
PEGPU License, Source, and Third-Party Notice
=============================================

This installer installs PEGPU and, when selected or included by the package,
PEGPU Machine. They are related applications, but they are distributed with a
visible architecture, repository, license, notice, and source boundary.

Project website:
https://pegpu.com


1. PEGPU.app
------------

PEGPU.app is the host-side macOS application. It provides the Swift/AppKit
launcher, UTM-derived embedded SPICE display client, ANGLE/CocoaSpice display
integration, local AI/runtime controls, model/runtime routing helpers,
file/port/terminal UI, sidecar metrics, local networking helpers, and
app-side orchestration.

Repository:
https://github.com/openresearchtools/PEGPU

The PEGPU.app application code is distributed under the Apache License,
Version 2.0, except where an individual file or bundled component states a
different license.

PEGPU.app bundles and/or builds against app-side runtime components including
SPICE, GLib, GStreamer, ANGLE, CocoaSpice, UTM-derived GUI display work,
Swift package dependencies, Go helper dependencies, and related support
libraries. Those components keep their own license terms, including
permissive licenses and LGPL-family licenses where applicable. File-level
and component-level notices remain authoritative.

Installed app-side notices, runtime/distribution license records, source
archives, and source-archive legal sidecars are available at:

/Applications/PEGPU.app/Contents/Resources/PEGPURoot/legal/generated

Key installed PEGPU.app legal/source files:

- NOTICES
- LICENSES
- GUEST-VM-INSTALL-NOTICES.md
- source/PEGPU-app-source.tar.gz
- source/PEGPU-app-source.NOTICES
- source/PEGPU-app-source.LICENSES
- source/PEGPU-app-source.manifest.json
- source/display-runtime-source.tar.gz
- source/display-runtime-source.NOTICES
- source/display-runtime-source.LICENSES
- source/display-runtime-source.manifest.json

NOTICES explains the app/Machine split and where each app's legal and source
records live. LICENSES is the consolidated license record for the installed
PEGPU.app application/runtime distribution. Source archives are broader than
the runtime closure: they can include upstream source trees, build recipes,
backend implementations, generated inputs, tests, examples, and source-only
build tools used for provenance or reproducible builds. The legal records for
those archive contents are generated next to each archive as NOTICES, LICENSES,
and manifest sidecars.
GUEST-VM-INSTALL-NOTICES.md describes Debian APT, GUI, DMA driver, and optional
NVIDIA/CUDA install activity inside the Linux VM.
The PEGPU.app Help menu also opens the installed legal files, which list the
bundled source/provenance archive locations.
For convenience, PEGPU.app Help can render external PEGPU Machine notices and
licenses from the installed PEGPU Machine.app. The Help menu marks those
Machine-owned rows as EXTERNAL. PEGPU.app does not copy Machine legal text into
its own bundle.


App-side provenance includes:

UTM app and embedded display foundation:
https://github.com/utmapp/UTM

llama.cpp server/API conventions, chat/runtime surface, and web UI influence:
https://github.com/ggml-org/llama.cpp

llama-swap-style model routing idea:
https://github.com/mostlygeek/llama-swap

GOST-style TCP/UDP local forwarding model:
https://github.com/ginuerzh/gost

TurboQuant llama.cpp-family runtime option:
https://github.com/TheTom/llama-cpp-turboquant


2. PEGPU Machine.app
--------------------

PEGPU Machine.app is the separate VM, DriverKit, VFIO, QEMU, firmware, and
guest-tools runtime application used by PEGPU virtual machines. It owns the
Machine-side passthrough mechanics and carries its own notices, license texts,
and source bundles.

Repository:
https://github.com/openresearchtools/PEGPU-machine

PEGPU Machine includes and packages Machine-side components including patched
QEMU, the Apple VFIO backend, the DriverKit host application, the
VFIOUserPCIDriver DriverKit system extension, the embedded qemu-vfio-apple
launcher/CLI, QEMU firmware and runtime payloads, bundled QEMU tools and
libraries, QEMU-side SPICE/virgl visual-runtime adaptations, guest-driver
packages, and guest-side apple_dma DKMS source materials where included by the
release.

Installed Machine-side notices, license texts, and source bundles are
available inside:

/Applications/PEGPU Machine.app/Contents/Resources

Key installed PEGPU Machine legal/source files:

- ThirdPartyNotices/NOTICES
- ThirdPartyNotices/LICENSES
- SourceBundles/PEGPU-Machine-<version>-source.tar.gz
- guest-tools/source/apple-dma-<version>.tar.gz

For convenience, PEGPU.app Help can render these external PEGPU Machine notices
and licenses from the installed PEGPU Machine.app. The Help menu marks those
Machine-owned rows as EXTERNAL. PEGPU.app does not copy Machine legal text into
its own bundle.

PEGPU Machine is QEMU-derived and is distributed from a patch stack over
recorded source layers. The source tree produced by that patch stack is
GPL-covered QEMU-derived source unless an individual file, component, or patch
hunk states a more specific license. QEMU as a whole is released under the
GNU General Public License, version 2. Individual files and bundled components
may carry GPL, LGPL, BSD-style, MIT-style, UBDL, or other notices; those
file-level and component-level notices remain authoritative.

The recorded PEGPU Machine source layers are:

1. A recorded vanilla QEMU base.
2. Scott J. Goldman's scottjg/qemu-vfio-apple wip layer.
3. QEMU-side visual-runtime work adapted from utmapp/qemu and
   utmapp/virglrenderer.
4. OpenResearchTools PEGPU Machine integration, packaging, guest-tools,
   installer, notice, and release layers.

Scott J. Goldman's scottjg/qemu-vfio-apple is the main Apple VFIO / DriverKit
/ QEMU passthrough base for PEGPU Machine. PEGPU Machine keeps that provenance
visible because Scott's project introduced the core Apple Silicon PCIe/eGPU
passthrough structure: a macOS DriverKit host app and dext, QEMU-side Apple
VFIO backend, embedded launcher, and guest-side apple_dma DMA companion driver.

Machine-side provenance includes:

Scott J. Goldman's qemu-vfio-apple Apple VFIO base:
https://github.com/scottjg/qemu-vfio-apple

QEMU-side UTM visual/runtime work:
https://github.com/utmapp/qemu

UTM virglrenderer work:
https://github.com/utmapp/virglrenderer

Upstream QEMU source:
https://gitlab.com/qemu-project/qemu


License and architecture boundary
---------------------------------

PEGPU uses a stricter form of the UTM / UTM-QEMU-style architecture: the
frontend, AI/runtime control surface, display client, routing, and
orchestration app is packaged separately from the GPL-covered Machine/QEMU
VM/runtime stack. The two apps have separate repositories, notices, source
archives, and runtime responsibilities.

- PEGPU.app contains the Apache-licensed launcher, GUI, app-side display
  client, AI/runtime controls, local routing helpers, and orchestration code.
- PEGPU Machine.app contains the GPL-covered QEMU-derived VM runtime,
  Apple VFIO backend, DriverKit host extension, firmware/runtime payloads,
  and guest-driver packaging.

The combined installer may install both applications into /Applications, but
the repositories, notices, source archives, and runtime responsibilities remain
separate. GPL-covered QEMU-derived code stays on the Machine side. App-side
launcher, display, AI, and orchestration work stays in PEGPU.app unless an
individual bundled component states otherwise.

The installed license texts are the controlling terms for each app and bundled
component, including any disclaimer of warranty and limitation of liability
stated in those licenses.


No affiliation
--------------

PEGPU and PEGPU Machine are not endorsed by, sponsored by, or affiliated with
Apple, NVIDIA, Fabrice Bellard, the QEMU project, Scott J. Goldman,
scottjg/qemu-vfio-apple, UTM, utmapp/qemu, utmapp/virglrenderer, llama.cpp,
llama-swap, GOST, TurboQuant, or their maintainers.
TEXT
if [ "$INCLUDE_MACHINE" != "1" ]; then
  cat > "$RESOURCES/WELCOME.html" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font: -apple-system-body; color: #1f2328; margin: 0; padding: 18px; }
    .top { display: flex; align-items: center; gap: 14px; margin-bottom: 12px; }
    img { width: 58px; height: 58px; border-radius: 10px; }
    h1 { font: -apple-system-title1; margin: 0; }
    p, li { line-height: 1.35; }
  </style>
</head>
<body>
  <div class="top">
    <img src="PEGPU-logo-transparent.png" alt="">
    <div>
      <h1>PEGPU</h1>
      <p>This artifact installs PEGPU.app.</p>
    </div>
  </div>
  <p>Combined public releases also install PEGPU Machine.app, the QEMU/VFIO/DriverKit virtual machine runtime used by PEGPU.</p>
  <p>More information: <a href="https://pegpu.com">pegpu.com</a>, <a href="https://github.com/openresearchtools/PEGPU">openresearchtools/PEGPU</a>, <a href="https://github.com/openresearchtools/PEGPU-machine">openresearchtools/PEGPU-machine</a>.</p>
  <p style="color:#667085;font-size:11px">* Compatibility and purpose labels only. PEGPU is not endorsed by, sponsored by, affiliated with, or encouraged by Apple, NVIDIA, Linux, Thunderbolt, QEMU, UTM, Debian, llama.cpp, llama-swap, GOST, TurboQuant, Scott J. Goldman, or any named company, protocol, project, or maintainer.</p>
</body>
</html>
HTML

  cat > "$RESOURCES/LICENSE.txt" <<'TEXT'
PEGPU installs PEGPU.app.

PEGPU.app is the Swift/AppKit application and app-side display client.
Notices and source archives are installed inside:

/Applications/PEGPU.app/Contents/Resources/PEGPURoot/legal/generated

Canonical installed legal files:

- NOTICES
- LICENSES
- GUEST-VM-INSTALL-NOTICES.md

This artifact package does not include PEGPU Machine.app. Combined releases
include PEGPU Machine.app and its separate QEMU/VFIO/DriverKit source bundles.
When PEGPU Machine.app is installed, PEGPU.app Help can render external PEGPU
Machine notices and licenses from the installed PEGPU Machine.app without
copying those Machine files into PEGPU.app.
The Help menu marks Machine-owned legal rows as EXTERNAL.

The installed license texts are the controlling terms for PEGPU.app and bundled
app-side components, including any disclaimer of warranty and limitation of
liability stated in those licenses.

Project links:

- https://pegpu.com
- https://github.com/openresearchtools/PEGPU
- https://github.com/openresearchtools/PEGPU-machine
TEXT
fi

pkgbuild \
  --root "$STAGE_APP" \
  --component-plist "$APP_COMPONENTS_PLIST" \
  --scripts "$SCRIPTS_APP" \
  --install-location / \
  --identifier com.pegpu.pkg.app \
  --version "$VERSION" \
  "$COMPONENTS/PEGPU-app.pkg" >/dev/null

if [ "$INCLUDE_MACHINE" = "1" ]; then
  pkgbuild \
    --root "$STAGE_MACHINE" \
    --component-plist "$MACHINE_COMPONENTS_PLIST" \
    --scripts "$SCRIPTS_MACHINE" \
    --install-location / \
    --identifier com.pegpu.pkg.machine \
    --version "$VERSION" \
    "$COMPONENTS/PEGPU-machine.pkg" >/dev/null
  pkgbuild \
    --nopayload \
    --scripts "$SCRIPTS_DRIVER" \
    --identifier com.pegpu.pkg.driver \
    --version "$VERSION" \
    "$COMPONENTS/PEGPU-driver.pkg" >/dev/null
fi

if [ "$INCLUDE_MACHINE" = "1" ]; then
  cat > "$WORK/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>PEGPU</title>
  <options customize="always" require-scripts="true" rootVolumeOnly="true" hostArchitectures="arm64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <installation-check script="sipDisabled()"/>
  <script><![CDATA[
var machinePayloadVersion = "$MACHINE_NEW_SHORT_VERSION";
var machinePayloadBuild = "$MACHINE_NEW_BUILD";

function commandText(result) {
  if (!result) { return ""; }
  if (result.stdout) { return String(result.stdout); }
  if (result.stderr) { return String(result.stderr); }
  return String(result);
}

var driverIdentifier = "com.pegpu.machine.VFIOUserPCIDriver";
var cachedDriverState = null;

function safeRunText() {
  try {
    return commandText(system.run.apply(system, arguments));
  } catch (error) {
    return "";
  }
}

function shellText(command) {
  return safeRunText("/bin/sh", "-c", command);
}

function textContainsDriver(text) {
  return String(text || "").indexOf(driverIdentifier) !== -1;
}

function sipDisabledState() {
  var text = safeRunText("/usr/bin/csrutil", "status");
  return /disabled/i.test(text);
}

function sipDisabled() {
  if (sipDisabledState()) { return true; }
  my.result.title = "System Integrity Protection must be disabled";
  my.result.message = "PEGPU Machine uses an ad-hoc DriverKit system extension for PCIe/eGPU passthrough. There is no useful installation path with SIP enabled.\n\nTo disable SIP on Apple Silicon:\n1. Shut down the Mac.\n2. Hold the power button until Startup Options appear.\n3. Open Options > Utilities > Terminal.\n4. Run: csrutil disable\n5. Restart macOS.\n6. Run this installer again.";
  return false;
}

function compareVersion(left, right) {
  var a = String(left || "").split(/[^0-9]+/);
  var b = String(right || "").split(/[^0-9]+/);
  var max = Math.max(a.length, b.length);
  for (var i = 0; i < max; i++) {
    var av = a[i] === "" || a[i] === undefined ? 0 : Number(a[i]);
    var bv = b[i] === "" || b[i] === undefined ? 0 : Number(b[i]);
    if (av > bv) { return 1; }
    if (av < bv) { return -1; }
  }
  return 0;
}

function driverState() {
  if (cachedDriverState !== null) { return cachedDriverState; }

  var listText = safeRunText("/usr/bin/systemextensionsctl", "list");
  if (!textContainsDriver(listText)) {
    listText += "\n" + shellText("/usr/bin/systemextensionsctl list 2>&1 || true");
  }
  if (textContainsDriver(listText)) {
    cachedDriverState = "installed";
    return cachedDriverState;
  }

  var registeredBundle = shellText("/usr/bin/find /Library/SystemExtensions -maxdepth 6 -name 'com.pegpu.machine.VFIOUserPCIDriver.dext' -print -quit 2>/dev/null || true");
  if (textContainsDriver(registeredBundle)) {
    cachedDriverState = "installed";
    return cachedDriverState;
  }

  if (/extension|bundleID|No system extensions/i.test(listText)) {
    cachedDriverState = "missing";
    return cachedDriverState;
  }

  cachedDriverState = "unknown";
  return cachedDriverState;
}

function driverStatusKnownMissing() {
  return driverState() === "missing";
}

function machineNeedsInstall() {
  var plistPath = "/Applications/PEGPU Machine.app/Contents/Info.plist";
  if (!system.files.fileExistsAtPath(plistPath)) {
    return true;
  }
  var plist = system.files.plistAtPath(plistPath);
  if (!plist) {
    return true;
  }
  var installedVersion = String(plist["CFBundleShortVersionString"] || "");
  var installedBuild = String(plist["CFBundleVersion"] || "");
  var versionCompare = compareVersion(machinePayloadVersion, installedVersion);
  if (versionCompare > 0) { return true; }
  if (versionCompare < 0) { return false; }
  return compareVersion(machinePayloadBuild, installedBuild) > 0;
}

function driverNeedsRefresh() {
  return machineNeedsInstall() || driverStatusKnownMissing();
}
  ]]></script>
  <welcome file="WELCOME.html" mime-type="text/html"/>
  <license file="LICENSE.txt" mime-type="text/plain"/>
  <conclusion file="CONCLUSION.txt" mime-type="text/plain"/>
  <choices-outline>
    <line choice="com.pegpu.install.app"/>
    <line choice="com.pegpu.install.machine"/>
  </choices-outline>
  <choice id="com.pegpu.install.app" title="PEGPU.app" description="Required main application installed in /Applications. Includes the launcher, GUI, app-side display client, AI/runtime controls, notices, and app-side source archives." start_selected="true" start_enabled="false" start_visible="true">
    <pkg-ref id="com.pegpu.pkg.app"/>
  </choice>
  <choice id="com.pegpu.install.machine" title="PEGPU Machine.app + DriverKit refresh/activation" description="Install or refresh the separate VM/QEMU/VFIO/DriverKit runtime app in /Applications. SIP must be disabled before this can be installed. DriverKit refresh/activation is bundled with this choice and does not run when this choice is not selected." start_selected="driverNeedsRefresh()" start_enabled="true" start_visible="true">
    <pkg-ref id="com.pegpu.pkg.machine"/>
    <pkg-ref id="com.pegpu.pkg.driver"/>
  </choice>
  <pkg-ref id="com.pegpu.pkg.app" version="$VERSION" onConclusion="none">PEGPU-app.pkg</pkg-ref>
  <pkg-ref id="com.pegpu.pkg.machine" version="$VERSION" onConclusion="RecommendRestart">PEGPU-machine.pkg</pkg-ref>
  <pkg-ref id="com.pegpu.pkg.driver" version="$VERSION" onConclusion="RecommendRestart">PEGPU-driver.pkg</pkg-ref>
</installer-gui-script>
XML
else
  cat > "$WORK/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>PEGPU</title>
  <options customize="always" require-scripts="true" rootVolumeOnly="true" hostArchitectures="arm64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <installation-check script="sipDisabled()"/>
  <script><![CDATA[
function commandText(result) {
  if (!result) { return ""; }
  if (result.stdout) { return String(result.stdout); }
  if (result.stderr) { return String(result.stderr); }
  return String(result);
}

function sipDisabled() {
  var result = system.run("/usr/bin/csrutil", "status");
  var text = commandText(result);
  if (/disabled/i.test(text)) {
    return true;
  }
  my.result.title = "System Integrity Protection must be disabled";
  my.result.message = "PEGPU releases require SIP to be disabled because combined releases install an ad-hoc DriverKit host extension.\n\nTo disable SIP on Apple Silicon:\n1. Shut down the Mac.\n2. Hold the power button until Startup Options appear.\n3. Open Options > Utilities > Terminal.\n4. Run: csrutil disable\n5. Restart macOS.\n6. Run this installer again.";
  return false;
}
  ]]></script>
  <welcome file="WELCOME.html" mime-type="text/html"/>
  <license file="LICENSE.txt" mime-type="text/plain"/>
  <conclusion file="CONCLUSION.txt" mime-type="text/plain"/>
  <choices-outline>
    <line choice="com.pegpu.install"/>
  </choices-outline>
  <choice id="com.pegpu.install" title="PEGPU.app" description="Main application: Apache-2.0 Swift/AppKit launcher, GUI, app-side display client, AI runtime controls, notices, and app-side source archives." start_selected="true">
    <pkg-ref id="com.pegpu.pkg.app"/>
  </choice>
  <pkg-ref id="com.pegpu.pkg.app" version="$VERSION" onConclusion="none">PEGPU-app.pkg</pkg-ref>
</installer-gui-script>
XML
fi

rm -f "$OUT"
productbuild \
  --distribution "$WORK/Distribution.xml" \
  --resources "$RESOURCES" \
  --package-path "$COMPONENTS" \
  "$OUT" >/dev/null

echo "$OUT"

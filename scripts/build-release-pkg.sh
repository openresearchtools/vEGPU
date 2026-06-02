#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vegpu-build"
BUILD_ROOT="${VEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
VERSION="${VERSION:-0.1.0}"
PACKAGE_CHANNEL="${VEGPU_PACKAGE_CHANNEL:-release}"
APP="${VEGPU_APP:-$BUILD_ROOT/vEGPU.app}"
MACHINE_APP="${VEGPU_MACHINE_APP:-/Applications/vEGPU Machine.app}"
REQUIRE_MACHINE_APP="${VEGPU_REQUIRE_MACHINE_APP:-1}"
REQUIRE_MACHINE_SOURCE="${VEGPU_REQUIRE_MACHINE_SOURCE:-0}"
case "$PACKAGE_CHANNEL" in
  release) DEFAULT_PKG_NAME="vEGPU-v$VERSION.pkg" ;;
  pre-release) DEFAULT_PKG_NAME="vEGPU-v$VERSION-pre-release.pkg" ;;
  artifact) DEFAULT_PKG_NAME="vEGPU-v$VERSION-artifact.pkg" ;;
  *) DEFAULT_PKG_NAME="vEGPU-v$VERSION-$PACKAGE_CHANNEL.pkg" ;;
esac
OUT="${OUT:-$BUILD_ROOT/$DEFAULT_PKG_NAME}"
WORK="${VEGPU_PKG_BUILD_DIR:-$BUILD_ROOT/pkg}"
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
  printf 'Missing vEGPU.app: %s\n' "$APP" >&2
  exit 1
fi
if [ ! -d "$MACHINE_APP" ]; then
  if [ "$REQUIRE_MACHINE_APP" = "1" ]; then
    printf 'Missing vEGPU Machine.app: %s\n' "$MACHINE_APP" >&2
    printf 'Set VEGPU_MACHINE_APP to the built Machine app before packaging, or set VEGPU_REQUIRE_MACHINE_APP=0 for an app-only artifact package.\n' >&2
    exit 1
  fi
else
  INCLUDE_MACHINE=1
fi

rm -rf "$WORK"
mkdir -p "$COMPONENTS" "$RESOURCES" "$SCRIPTS_APP" "$SCRIPTS_MACHINE" "$SCRIPTS_DRIVER" "$STAGE_APP/Applications" "$STAGE_MACHINE/Applications"

/usr/bin/ditto "$APP" "$STAGE_APP/Applications/vEGPU.app"
if [ "$INCLUDE_MACHINE" = "1" ]; then
  /usr/bin/ditto "$MACHINE_APP" "$STAGE_MACHINE/Applications/vEGPU Machine.app"
  MACHINE_INFO="$STAGE_MACHINE/Applications/vEGPU Machine.app/Contents/Info.plist"
  MACHINE_NEW_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MACHINE_INFO" 2>/dev/null || true)"
  MACHINE_NEW_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MACHINE_INFO" 2>/dev/null || true)"
  MACHINE_SOURCE_DEST="$STAGE_MACHINE/Applications/vEGPU Machine.app/Contents/Resources/SourceBundles"
  mkdir -p "$MACHINE_SOURCE_DEST"
  machine_source_count=0
  while IFS= read -r source_tar; do
    cp "$source_tar" "$MACHINE_SOURCE_DEST/"
    machine_source_count=$((machine_source_count + 1))
  done < <(find "$(dirname "$MACHINE_APP")" -maxdepth 1 -type f \( -name '*source*.tar.gz' -o -name '*source*.tar.xz' -o -name '*source*.tgz' \) | sort)
  if [ "$REQUIRE_MACHINE_SOURCE" = "1" ] && [ "$machine_source_count" -eq 0 ]; then
    printf 'Missing vEGPU Machine source tarball next to Machine app: %s\n' "$(dirname "$MACHINE_APP")" >&2
    exit 1
  fi
  /usr/bin/codesign --force --sign - "$STAGE_MACHINE/Applications/vEGPU Machine.app" >/dev/null
fi

test -f "$STAGE_APP/Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated/source/vEGPU-app-source.tar.gz"
test -f "$STAGE_APP/Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated/source/display-runtime-source.tar.gz"

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
vEGPU requires System Integrity Protection (SIP) to be disabled before installation.

To disable SIP on Apple Silicon:
1. Shut down the Mac.
2. Hold the power button until startup options appear.
3. Open Options, then Utilities, then Terminal.
4. Run: csrutil disable
5. Restart macOS and run this installer again.

This is required because vEGPU Machine installs and loads an ad-hoc DriverKit
host extension for PCIe/eGPU passthrough. Do not install vEGPU on a machine
that holds sensitive data unless you accept that security tradeoff.
TEXT
  exit 1
fi
SCRIPT

  if [ "$scope" = "driver" ]; then
    cat >> "$dir/preinstall" <<'SCRIPT'

VEGPU_INSTALLED_MACHINE="/Applications/vEGPU Machine.app"
VEGPU_MACHINE_EXECUTABLE="$VEGPU_INSTALLED_MACHINE/Contents/MacOS/vEGPU Machine"
VEGPU_DRIVER_ID="com.vegpu.machine.VFIOUserPCIDriver"
VEGPU_DRIVER_REFRESH_MARKER="/tmp/com.vegpu.machine.pkg.driver-refresh-needed"
VEGPU_DRIVER_LOG="/var/log/vegpu-driver-install.log"

rm -f "$VEGPU_DRIVER_REFRESH_MARKER"
mkdir -p "$(dirname "$VEGPU_DRIVER_LOG")"
touch "$VEGPU_DRIVER_LOG"
chmod 0644 "$VEGPU_DRIVER_LOG" 2>/dev/null || true
exec >>"$VEGPU_DRIVER_LOG" 2>&1
echo "---- vEGPU Machine preinstall driver refresh $(date -u '+%Y-%m-%dT%H:%M:%SZ') ----"

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
  /usr/bin/systemextensionsctl list 2>/dev/null | /usr/bin/grep -Fq "$VEGPU_DRIVER_ID"
}

force_uninstall_driver() {
  /usr/bin/systemextensionsctl uninstall - "$VEGPU_DRIVER_ID"
}

touch "$VEGPU_DRIVER_REFRESH_MARKER"
echo "vEGPU DriverKit component selected. Preparing macOS DriverKit extension before activation."
if [ -x "$VEGPU_MACHINE_EXECUTABLE" ]; then
  echo "Existing vEGPU Machine app found. Asking it to deactivate the current driver."
  if run_as_console_user_with_timeout 20 "$VEGPU_MACHINE_EXECUTABLE" --driver-deactivate; then
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
  echo "Existing vEGPU Machine app is missing."
  if driver_installed; then
    echo "Driver extension is still listed without its owning app; attempting forced system extension uninstall."
    force_uninstall_driver || echo "Forced macOS driver uninstall did not complete; continuing package replacement." >&2
  else
    echo "No existing vEGPU DriverKit extension is listed; no preinstall driver removal needed."
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

clear_app_attrs "/Applications/vEGPU.app"
clear_app_attrs "/Applications/vEGPU Machine.app"
SCRIPT

  if [ "$scope" = "driver" ]; then
    cat >> "$dir/postinstall" <<'SCRIPT'

VEGPU_MACHINE_EXECUTABLE="/Applications/vEGPU Machine.app/Contents/MacOS/vEGPU Machine"
VEGPU_DRIVER_REFRESH_MARKER="/tmp/com.vegpu.machine.pkg.driver-refresh-needed"
VEGPU_DRIVER_LOG="/var/log/vegpu-driver-install.log"
VEGPU_DRIVER_ID="com.vegpu.machine.VFIOUserPCIDriver"
mkdir -p "$(dirname "$VEGPU_DRIVER_LOG")"
touch "$VEGPU_DRIVER_LOG"
chmod 0644 "$VEGPU_DRIVER_LOG" 2>/dev/null || true
exec >>"$VEGPU_DRIVER_LOG" 2>&1
echo "---- vEGPU Machine postinstall driver activation $(date -u '+%Y-%m-%dT%H:%M:%SZ') ----"

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
  echo "Current macOS system extension state for $VEGPU_DRIVER_ID:"
  if /usr/bin/systemextensionsctl list 2>/dev/null | /usr/bin/grep -F "$VEGPU_DRIVER_ID"; then
    return 0
  fi
  echo "Driver extension is not listed yet."
}

if [ ! -f "$VEGPU_DRIVER_REFRESH_MARKER" ]; then
  echo "vEGPU Machine driver refresh was not requested; leaving existing driver state unchanged."
elif [ -x "$VEGPU_MACHINE_EXECUTABLE" ]; then
  echo "New vEGPU Machine app is installed. Asking it to activate the DriverKit extension."
  if run_as_console_user_with_timeout 45 "$VEGPU_MACHINE_EXECUTABLE" --driver-activate; then
    echo "vEGPU Machine macOS driver activation request submitted."
    log_driver_status || true
  else
    echo "vEGPU Machine macOS driver activation request failed. Open vEGPU Machine or vEGPU.app Runtime > Install Driver and retry after approving the extension in System Settings."
    log_driver_status || true
  fi
else
  echo "vEGPU Machine executable is missing after installation: $VEGPU_MACHINE_EXECUTABLE" >&2
  log_driver_status || true
fi
rm -f "$VEGPU_DRIVER_REFRESH_MARKER"
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

APP_COMPONENTS_PLIST="$WORK/vEGPU-app-components.plist"
MACHINE_COMPONENTS_PLIST="$WORK/vEGPU-machine-components.plist"
write_nonrelocatable_component_plist "$STAGE_APP" "$APP_COMPONENTS_PLIST"
if [ "$INCLUDE_MACHINE" = "1" ]; then
  write_nonrelocatable_component_plist "$STAGE_MACHINE" "$MACHINE_COMPONENTS_PLIST"
fi

if [ -f "$ROOT/Resources/Assets/vEGPU-logo-transparent.png" ]; then
  cp "$ROOT/Resources/Assets/vEGPU-logo-transparent.png" "$RESOURCES/vEGPU-logo-transparent.png"
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
    <img src="vEGPU-logo-transparent.png" alt="">
    <div>
      <h1>vEGPU</h1>
      <p>NVIDIA* eGPU passthrough and AI runtime orchestration for Apple Silicon Macs.</p>
    </div>
  </div>
  <p class="footnote">* Compatibility and purpose labels only. vEGPU is not endorsed by, sponsored by, affiliated with, or encouraged by Apple, NVIDIA, Linux, Thunderbolt, QEMU, UTM, Debian, llama.cpp, llama-swap, GOST, TurboQuant, Scott J. Goldman, or any named company, protocol, project, or maintainer.</p>

  <h2>Important: SIP Must Be Disabled</h2>
  <p class="warn">System Integrity Protection must be disabled before installing vEGPU Machine's DriverKit passthrough component. There is no useful installation path with SIP enabled: this installer checks SIP before installation and will stop on a SIP-enabled Mac.</p>
  <p>vEGPU Machine uses an ad-hoc DriverKit system extension for PCIe/eGPU passthrough. Disabling SIP is a serious macOS security tradeoff.</p>
  <p>To disable SIP on Apple Silicon: shut down the Mac, hold the power button until Startup Options appear, open Options &gt; Utilities &gt; Terminal, run <span class="code">csrutil disable</span>, restart macOS, and run this installer again.</p>

  <h2>What This Installer Installs</h2>
  <p>This installer places two related applications in <strong>/Applications</strong> and keeps their license, source, and runtime boundary visible.</p>
  <h3>vEGPU.app</h3>
  <p>Apache-2.0 Swift/AppKit launcher and host-side application. It contains the UTM-derived embedded SPICE GUI display side, ANGLE/CocoaSpice integration, AI runtime controls, local routing helpers, app-side orchestration, notices, and app-side source/provenance archives.</p>
  <p>Repository: <a href="https://github.com/openresearchtools/vEGPU">https://github.com/openresearchtools/vEGPU</a></p>
  <h3>vEGPU Machine.app</h3>
  <p>Separate QEMU/VFIO/DriverKit virtual-machine runtime and macOS driver host. It contains the Machine-side passthrough mechanics, QEMU-derived GPL source bundles, firmware/runtime payloads, guest tools, guest-driver materials, DriverKit activation helpers, and Machine-side notices.</p>
  <p>Repository: <a href="https://github.com/openresearchtools/vEGPU-machine">https://github.com/openresearchtools/vEGPU-machine</a></p>

  <h2>Architecture and Source Boundary</h2>
  <p class="boundary">vEGPU follows a UTM / UTM-QEMU-style split with a visible boundary: app-side launcher, display, AI, routing, and orchestration work stays in vEGPU.app. GPL-covered QEMU, VFIO, DriverKit, firmware, VM runtime, and guest-driver mechanics stay in vEGPU Machine.app.</p>
  <p>The embedded display side is partially based on UTM app work. The Machine side builds on Scott J. Goldman's scottjg/qemu-vfio-apple as the main Apple VFIO/DriverKit/QEMU base, with additional QEMU-side visual-runtime work adapted from UTM QEMU and UTM virglrenderer.</p>

  <h2>Installation Behavior</h2>
  <p>The Installation Type screen shows separate choices for vEGPU.app, vEGPU Machine.app files, and DriverKit extension refresh/activation.</p>
  <p>For combined releases, vEGPU Machine.app is selected by default when it is missing or older than the installer payload. DriverKit refresh/activation is selected by default when Machine.app is changing or the DriverKit extension is not currently installed.</p>
  <p>If the installed vEGPU Machine app is the same or newer version and its DriverKit extension is already installed, the Machine and DriverKit choices remain visible but are not selected by default.</p>
  <p>When DriverKit refresh/activation is selected, the installer attempts to ask the existing vEGPU Machine app to deactivate the old DriverKit extension when possible. Forced removal is used only when an old extension is still listed and graceful deactivation is unavailable or did not complete.</p>
  <p>The installer then asks the installed vEGPU Machine.app to submit a fresh DriverKit activation request and writes driver-install diagnostics to <span class="code">/var/log/vegpu-driver-install.log</span>.</p>
  <p>macOS may still require approval in System Settings and/or a restart before the driver becomes active. This installer does not bypass Apple's system-extension approval flow.</p>

  <h2>More Information</h2>
  <p class="links">Project website: <a href="https://vegpu.com">https://vegpu.com</a><br>Main app repository: <a href="https://github.com/openresearchtools/vEGPU">https://github.com/openresearchtools/vEGPU</a><br>Machine repository: <a href="https://github.com/openresearchtools/vEGPU-machine">https://github.com/openresearchtools/vEGPU-machine</a></p>
</body>
</html>
HTML

cat > "$RESOURCES/CONCLUSION.txt" <<'TEXT'
Installation finished.

If DriverKit extension refresh/activation was selected, the installer attempted
to deactivate the old macOS DriverKit extension and submit the new driver
activation request through the installed vEGPU Machine.app. macOS may still
require approval in System Settings.

Driver install log:
/var/log/vegpu-driver-install.log

You can close this installer and restart macOS later. Restart before launching
vEGPU with eGPUs attached. If the driver still shows as pending after approval,
open vEGPU.app and use Runtime > Install Driver to retry the same vEGPU Machine
helper path.

Use each app's Help menu to open licenses, notices, and bundled source archives.
TEXT

cat > "$RESOURCES/LICENSE.txt" <<'TEXT'
vEGPU License, Source, and Third-Party Notice
=============================================

This installer installs vEGPU and, when selected or included by the package,
vEGPU Machine. They are related applications, but they are distributed with a
visible architecture, repository, license, notice, and source boundary.

Project website:
https://vegpu.com


1. vEGPU.app
------------

vEGPU.app is the host-side macOS application. It provides the Swift/AppKit
launcher, UTM-derived embedded SPICE display client, ANGLE/CocoaSpice display
integration, local AI/runtime controls, model/runtime routing helpers,
file/port/terminal UI, sidecar metrics, local networking helpers, and
app-side orchestration.

Repository:
https://github.com/openresearchtools/vEGPU

The vEGPU.app application code is distributed under the Apache License,
Version 2.0, except where an individual file or bundled component states a
different license.

vEGPU.app bundles and/or builds against app-side runtime components including
SPICE, GLib, GStreamer, ANGLE, CocoaSpice, UTM-derived GUI display work,
Swift package dependencies, Go helper dependencies, and related support
libraries. Those components keep their own license terms, including
permissive licenses and LGPL-family licenses where applicable. File-level
and component-level notices remain authoritative.

Installed app-side notices, license texts, source records, and corresponding
source/provenance archives are available at:

/Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated

Key installed vEGPU.app legal/source files:

- NOTICES.md
- manifest.json
- licenses/
- source/vEGPU-app-source.tar.gz
- source/display-runtime-source.tar.gz

The vEGPU.app Help menu also opens the installed legal bundle and exposes the
bundled source/provenance archives.


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


2. vEGPU Machine.app
--------------------

vEGPU Machine.app is the separate VM, DriverKit, VFIO, QEMU, firmware, and
guest-tools runtime application used by vEGPU virtual machines. It owns the
Machine-side passthrough mechanics and carries its own notices, license texts,
and source bundles.

Repository:
https://github.com/openresearchtools/vEGPU-machine

vEGPU Machine includes and packages Machine-side components including patched
QEMU, the Apple VFIO backend, the DriverKit host application, the
VFIOUserPCIDriver DriverKit system extension, the embedded qemu-vfio-apple
launcher/CLI, QEMU firmware and runtime payloads, bundled QEMU tools and
libraries, QEMU-side SPICE/virgl visual-runtime adaptations, guest-driver
packages, and guest-side apple_dma source/prebuilt/DKMS materials where
included by the release.

Installed Machine-side notices, license texts, and source bundles are
available inside:

/Applications/vEGPU Machine.app/Contents/Resources

Key installed vEGPU Machine legal/source files:

- ThirdPartyNotices/NOTICES
- ThirdPartyNotices/LICENSES
- SourceBundles/vEGPU-Machine-<version>-source.tar.gz
- guest-tools/source/apple-dma-<version>.tar.gz

vEGPU Machine is QEMU-derived and is distributed from a patch stack over
recorded source layers. The source tree produced by that patch stack is
GPL-covered QEMU-derived source unless an individual file, component, or patch
hunk states a more specific license. QEMU as a whole is released under the
GNU General Public License, version 2. Individual files and bundled components
may carry GPL, LGPL, BSD-style, MIT-style, UBDL, or other notices; those
file-level and component-level notices remain authoritative.

The recorded vEGPU Machine source layers are:

1. A recorded vanilla QEMU base.
2. Scott J. Goldman's scottjg/qemu-vfio-apple wip layer.
3. QEMU-side visual-runtime work adapted from utmapp/qemu and
   utmapp/virglrenderer.
4. OpenResearchTools vEGPU Machine integration, packaging, guest-tools,
   installer, notice, and release layers.

Scott J. Goldman's scottjg/qemu-vfio-apple is the main Apple VFIO / DriverKit
/ QEMU passthrough base for vEGPU Machine. vEGPU Machine keeps that provenance
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

vEGPU follows a UTM / UTM-QEMU-style split with a visible boundary between
the host app and the VM runtime:

- vEGPU.app contains the Apache-licensed launcher, GUI, app-side display
  client, AI/runtime controls, local routing helpers, and orchestration code.
- vEGPU Machine.app contains the GPL-covered QEMU-derived VM runtime,
  Apple VFIO backend, DriverKit host extension, firmware/runtime payloads,
  and guest-driver packaging.

The combined installer may install both applications into /Applications, but
the repositories, notices, source archives, and runtime responsibilities remain
separate. GPL-covered QEMU-derived code stays on the Machine side. App-side
launcher, display, AI, and orchestration work stays in vEGPU.app unless an
individual bundled component states otherwise.


No affiliation
--------------

vEGPU and vEGPU Machine are not endorsed by, sponsored by, or affiliated with
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
    <img src="vEGPU-logo-transparent.png" alt="">
    <div>
      <h1>vEGPU</h1>
      <p>This artifact installs vEGPU.app.</p>
    </div>
  </div>
  <p>Combined public releases also install vEGPU Machine.app, the QEMU/VFIO/DriverKit virtual machine runtime used by vEGPU.</p>
  <p>More information: <a href="https://vegpu.com">vegpu.com</a>, <a href="https://github.com/openresearchtools/vEGPU">openresearchtools/vEGPU</a>, <a href="https://github.com/openresearchtools/vEGPU-machine">openresearchtools/vEGPU-machine</a>.</p>
  <p style="color:#667085;font-size:11px">* Compatibility and purpose labels only. vEGPU is not endorsed by, sponsored by, affiliated with, or encouraged by Apple, NVIDIA, Linux, Thunderbolt, QEMU, UTM, Debian, llama.cpp, llama-swap, GOST, TurboQuant, Scott J. Goldman, or any named company, protocol, project, or maintainer.</p>
</body>
</html>
HTML

  cat > "$RESOURCES/LICENSE.txt" <<'TEXT'
vEGPU installs vEGPU.app.

vEGPU.app is the Swift/AppKit application and app-side display client.
Notices and source archives are installed inside:

/Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated

This artifact package does not include vEGPU Machine.app. Combined releases
include vEGPU Machine.app and its separate QEMU/VFIO/DriverKit source bundles.

Project links:

- https://vegpu.com
- https://github.com/openresearchtools/vEGPU
- https://github.com/openresearchtools/vEGPU-machine
TEXT
fi

pkgbuild \
  --root "$STAGE_APP" \
  --component-plist "$APP_COMPONENTS_PLIST" \
  --scripts "$SCRIPTS_APP" \
  --install-location / \
  --identifier com.vegpu.pkg.app \
  --version "$VERSION" \
  "$COMPONENTS/vEGPU-app.pkg" >/dev/null

if [ "$INCLUDE_MACHINE" = "1" ]; then
  pkgbuild \
    --root "$STAGE_MACHINE" \
    --component-plist "$MACHINE_COMPONENTS_PLIST" \
    --scripts "$SCRIPTS_MACHINE" \
    --install-location / \
    --identifier com.vegpu.pkg.machine \
    --version "$VERSION" \
    "$COMPONENTS/vEGPU-machine.pkg" >/dev/null
  pkgbuild \
    --nopayload \
    --scripts "$SCRIPTS_DRIVER" \
    --identifier com.vegpu.pkg.driver \
    --version "$VERSION" \
    "$COMPONENTS/vEGPU-driver.pkg" >/dev/null
fi

if [ "$INCLUDE_MACHINE" = "1" ]; then
  cat > "$WORK/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>vEGPU</title>
  <options customize="always" require-scripts="true" rootVolumeOnly="true"/>
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

function sipDisabledState() {
  var result = system.run("/usr/bin/csrutil", "status");
  var text = commandText(result);
  return /disabled/i.test(text);
}

function sipDisabled() {
  if (sipDisabledState()) { return true; }
  my.result.title = "System Integrity Protection must be disabled";
  my.result.message = "vEGPU Machine uses an ad-hoc DriverKit system extension for PCIe/eGPU passthrough. There is no useful installation path with SIP enabled.\n\nTo disable SIP on Apple Silicon:\n1. Shut down the Mac.\n2. Hold the power button until Startup Options appear.\n3. Open Options > Utilities > Terminal.\n4. Run: csrutil disable\n5. Restart macOS.\n6. Run this installer again.";
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

function driverInstalled() {
  var result = system.run("/usr/bin/systemextensionsctl", "list");
  var text = commandText(result);
  return text.indexOf("com.vegpu.machine.VFIOUserPCIDriver") !== -1;
}

function machineNeedsInstall() {
  var plistPath = "/Applications/vEGPU Machine.app/Contents/Info.plist";
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
  return machineNeedsInstall() || !driverInstalled();
}
  ]]></script>
  <welcome file="WELCOME.html" mime-type="text/html"/>
  <license file="LICENSE.txt" mime-type="text/plain"/>
  <conclusion file="CONCLUSION.txt" mime-type="text/plain"/>
  <choices-outline>
    <line choice="com.vegpu.status.sip"/>
    <line choice="com.vegpu.status.machine.current"/>
    <line choice="com.vegpu.status.machine.needs"/>
    <line choice="com.vegpu.status.driver.installed"/>
    <line choice="com.vegpu.status.driver.missing"/>
    <line choice="com.vegpu.install.app"/>
    <line choice="com.vegpu.install.machine"/>
    <line choice="com.vegpu.install.driver"/>
  </choices-outline>
  <choice id="com.vegpu.status.sip" title="SIP disabled" description="System Integrity Protection is disabled, so the DriverKit passthrough installer can continue. If SIP were enabled, this installer would stop before installation and show the Recovery instructions." start_selected="true" start_enabled="false" start_visible="true"/>
  <choice id="com.vegpu.status.machine.current" title="vEGPU Machine.app already installed/current" description="The installed vEGPU Machine.app is the same version or newer than this package, so the Machine app file payload is not selected by default." start_selected="true" start_enabled="false" start_visible="!machineNeedsInstall()"/>
  <choice id="com.vegpu.status.machine.needs" title="vEGPU Machine.app missing or older" description="vEGPU Machine.app is missing or older than this package, so the Machine app file payload is selected by default." start_selected="false" start_enabled="false" start_visible="machineNeedsInstall()"/>
  <choice id="com.vegpu.status.driver.installed" title="DriverKit extension installed" description="systemextensionsctl currently lists com.vegpu.machine.VFIOUserPCIDriver. DriverKit refresh is selected only if Machine.app is changing." start_selected="true" start_enabled="false" start_visible="driverInstalled()"/>
  <choice id="com.vegpu.status.driver.missing" title="DriverKit extension not installed" description="systemextensionsctl does not currently list com.vegpu.machine.VFIOUserPCIDriver, so DriverKit refresh/activation is selected by default." start_selected="false" start_enabled="false" start_visible="!driverInstalled()"/>
  <choice id="com.vegpu.install.app" title="vEGPU.app" description="Required main application installed in /Applications. Includes the launcher, GUI, app-side display client, AI/runtime controls, notices, and app-side source archives." start_selected="true" start_enabled="false" start_visible="true">
    <pkg-ref id="com.vegpu.pkg.app"/>
  </choice>
  <choice id="com.vegpu.install.machine" title="vEGPU Machine.app" description="Install or refresh the separate VM/QEMU/VFIO/DriverKit runtime app in /Applications." start_selected="machineNeedsInstall()" start_enabled="true" start_visible="true">
    <pkg-ref id="com.vegpu.pkg.machine"/>
  </choice>
  <choice id="com.vegpu.install.driver" title="DriverKit extension refresh/activation" description="Deactivate any old vEGPU DriverKit extension, force-uninstall only if it remains listed, then activate the installed vEGPU Machine DriverKit extension." start_selected="driverNeedsRefresh()" start_enabled="true" start_visible="true">
    <pkg-ref id="com.vegpu.pkg.driver"/>
  </choice>
  <pkg-ref id="com.vegpu.pkg.app" version="$VERSION" onConclusion="none">vEGPU-app.pkg</pkg-ref>
  <pkg-ref id="com.vegpu.pkg.machine" version="$VERSION" onConclusion="none">vEGPU-machine.pkg</pkg-ref>
  <pkg-ref id="com.vegpu.pkg.driver" version="$VERSION" onConclusion="none">vEGPU-driver.pkg</pkg-ref>
</installer-gui-script>
XML
else
  cat > "$WORK/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>vEGPU</title>
  <options customize="always" require-scripts="true" rootVolumeOnly="true"/>
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
  my.result.message = "vEGPU releases require SIP to be disabled because combined releases install an ad-hoc DriverKit host extension.\n\nTo disable SIP on Apple Silicon:\n1. Shut down the Mac.\n2. Hold the power button until Startup Options appear.\n3. Open Options > Utilities > Terminal.\n4. Run: csrutil disable\n5. Restart macOS.\n6. Run this installer again.";
  return false;
}
  ]]></script>
  <welcome file="WELCOME.html" mime-type="text/html"/>
  <license file="LICENSE.txt" mime-type="text/plain"/>
  <conclusion file="CONCLUSION.txt" mime-type="text/plain"/>
  <choices-outline>
    <line choice="com.vegpu.install"/>
  </choices-outline>
  <choice id="com.vegpu.install" title="vEGPU.app" description="Main application: Apache-2.0 Swift/AppKit launcher, GUI, app-side display client, AI runtime controls, notices, and app-side source archives." start_selected="true">
    <pkg-ref id="com.vegpu.pkg.app"/>
  </choice>
  <pkg-ref id="com.vegpu.pkg.app" version="$VERSION" onConclusion="none">vEGPU-app.pkg</pkg-ref>
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

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
mkdir -p "$COMPONENTS" "$RESOURCES" "$SCRIPTS_APP" "$SCRIPTS_MACHINE" "$STAGE_APP/Applications" "$STAGE_MACHINE/Applications"

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

  if [ "$scope" = "machine" ]; then
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
echo "vEGPU Machine component selected. Preparing macOS DriverKit extension before replacing or refreshing the host app."
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

  if [ "$scope" = "machine" ]; then
    cat >> "$dir/postinstall" <<'SCRIPT'

VEGPU_MACHINE_EXECUTABLE="/Applications/vEGPU Machine.app/Contents/MacOS/vEGPU Machine"
VEGPU_DRIVER_REFRESH_MARKER="/tmp/com.vegpu.machine.pkg.driver-refresh-needed"
VEGPU_DRIVER_LOG="/var/log/vegpu-driver-install.log"
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

if [ ! -f "$VEGPU_DRIVER_REFRESH_MARKER" ]; then
  echo "vEGPU Machine driver refresh was not requested; leaving existing driver state unchanged."
elif [ -x "$VEGPU_MACHINE_EXECUTABLE" ]; then
  echo "New vEGPU Machine app is installed. Asking it to activate the DriverKit extension."
  if run_as_console_user_with_timeout 45 "$VEGPU_MACHINE_EXECUTABLE" --driver-activate; then
    echo "vEGPU Machine macOS driver activation request submitted."
    run_as_console_user_with_timeout 15 "$VEGPU_MACHINE_EXECUTABLE" --driver-status --json || true
  else
    echo "vEGPU Machine macOS driver activation request failed. Open vEGPU Machine or vEGPU.app Runtime > Install Driver and retry after approving the extension in System Settings."
  fi
else
  echo "vEGPU Machine executable is missing after installation: $VEGPU_MACHINE_EXECUTABLE" >&2
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
    p, li { line-height: 1.32; }
    ul { margin: 8px 0 8px 20px; padding: 0; }
    .warn { border-left: 4px solid #d1242f; padding-left: 10px; margin: 10px 0; }
    .boundary { border-left: 4px solid #0969da; padding-left: 10px; margin: 10px 0; }
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
  <p>This installer puts two related applications in <strong>/Applications</strong> and keeps their license/source boundary visible:</p>
  <ul>
    <li><strong>vEGPU.app</strong>: Apache-2.0 Swift/AppKit launcher, UTM-derived embedded SPICE GUI display side, ANGLE/CocoaSpice integration, AI runtime controls, local routing helpers, notices, and app-side source archives.</li>
    <li><strong>vEGPU Machine.app</strong>: separate QEMU/VFIO/DriverKit runtime and macOS driver host with QEMU-derived GPL source bundles, guest tools, and Machine-side notices.</li>
  </ul>
  <p class="boundary"><strong>Boundary:</strong> app-side launcher/display/AI work stays in vEGPU.app. GPL QEMU/VFIO/DriverKit mechanics stay in vEGPU Machine.app. The embedded display side is partially based on UTM app work; the Machine side builds on Scott J. Goldman's qemu-vfio-apple and UTM QEMU/virgl work.</p>
  <p class="warn"><strong>SIP must be disabled.</strong> The installer checks this before installation and will stop on a SIP-enabled Mac.</p>
  <p>The Installation Type screen shows what will be installed. vEGPU Machine is selected by default when it is missing, older, or the same version with no installed DriverKit extension. If selected, the installer asks the existing Machine app to deactivate the old driver when possible, force-uninstalls only when an old extension is still listed, installs or refreshes vEGPU Machine.app, then asks the newly installed app to activate the driver. macOS may still require approval in System Settings before the driver becomes active.</p>
  <p class="links">More information: <a href="https://vegpu.com">vegpu.com</a>, <a href="https://github.com/openresearchtools/vEGPU">openresearchtools/vEGPU</a>, <a href="https://github.com/openresearchtools/vEGPU-machine">openresearchtools/vEGPU-machine</a>.</p>
  <p class="footnote">* Compatibility and purpose labels only. vEGPU is not endorsed by, sponsored by, affiliated with, or encouraged by Apple, NVIDIA, Linux, Thunderbolt, QEMU, UTM, Debian, llama.cpp, llama-swap, GOST, TurboQuant, Scott J. Goldman, or any named company, protocol, project, or maintainer.</p>
</body>
</html>
HTML

cat > "$RESOURCES/CONCLUSION.txt" <<'TEXT'
Installation finished.

If vEGPU Machine.app was selected, the installer attempted to deactivate the old
macOS DriverKit extension, install/refresh vEGPU Machine.app, and submit the new
driver activation request. macOS may still require approval in System Settings.

Driver install log:
/var/log/vegpu-driver-install.log

Restart macOS before launching vEGPU with eGPUs attached. If the driver still
shows as pending after approval, open vEGPU.app and use Runtime > Install Driver
to retry the same vEGPU Machine helper path.

Use each app's Help menu to open licenses, notices, and bundled source archives.
TEXT

cat > "$RESOURCES/LICENSE.txt" <<'TEXT'
vEGPU License and Source Notice
===============================

This package installs two related projects/applications:

1. vEGPU.app
   Launcher, Swift/AppKit GUI, UTM-derived embedded SPICE GUI display side,
   ANGLE/CocoaSpice integration, AI runtime controls, local routing helpers,
   and app-side orchestration. vEGPU.app is distributed under the permissive
   Apache License, Version 2.0.

   Repository:
   https://github.com/openresearchtools/vEGPU

   Bundled app-side runtime components include SPICE/GLib/GStreamer/ANGLE,
   CocoaSpice, UTM-derived GUI display work, and related support libraries,
   with their own license terms including permissive and LGPL-family
   components. The app bundle carries notices and corresponding
   source/provenance archives for those components.

   App/runtime provenance includes:
   - UTM app display work: https://github.com/utmapp/UTM
   - llama.cpp chat/runtime surface: https://github.com/ggml-org/llama.cpp
   - llama-swap-style model routing: https://github.com/mostlygeek/llama-swap
   - GOST-style Mac-to-VM and VM-to-Mac forwarding: https://github.com/ginuerzh/gost
   - TurboQuant runtime option: https://github.com/TheTom/llama-cpp-turboquant

   Notices and source archives:
   /Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated

2. vEGPU Machine.app
   DriverKit/VFIO/QEMU virtual machine runtime, firmware, guest tools, and
   Machine source bundles.

   Repository:
   https://github.com/openresearchtools/vEGPU-machine

   Notices and source bundles:
   /Applications/vEGPU Machine.app/Contents/Resources

Project website:
https://vegpu.com

After installation, licenses and notices are available in both installed
applications from the Help menu. The package also bundles the corresponding
source tarballs/source bundles for both applications for licensing obligations.

System Integrity Protection must be disabled before installation. vEGPU Machine
uses an ad-hoc DriverKit host extension for PCIe/eGPU passthrough. To disable
SIP on Apple Silicon, shut down, hold the power button until startup options
appear, open Options > Utilities > Terminal, run `csrutil disable`, restart,
and then run this installer again.

For combined releases, the vEGPU Machine component is selected by default when
Machine is missing, older, or the same version with no installed DriverKit
extension. If Machine is the same/newer and the driver is already installed,
that component stays visible but unticked by default. If that component is
selected, the installer asks the existing Machine app to deactivate the old
driver when possible, force-uninstalls only when an old extension is still
listed, installs or refreshes vEGPU Machine.app, submits a fresh driver
activation request through the newly installed Machine app, logs the attempt to
/var/log/vegpu-driver-install.log, and then offers the normal macOS restart
choice so the driver state is clean.

Architecture and license boundary, following the UTM split
==========================================================

vEGPU follows the UTM and UTM-QEMU style split with a harder visible boundary:
vEGPU Machine handles the GPL DriverKit/QEMU/VM mechanics, while vEGPU handles
the launcher, GUI, app-side display client, and AI runtime layers. GPL-derived
QEMU code stays GPL-covered on the Machine side, app-side launcher/display work
stays separate, and the boundary remains visible in the installed apps,
repositories, notices, and source bundles.

vEGPU Machine is built as a patch stack over recorded QEMU-derived source.
QEMU as a whole is released under the GNU General Public License, version 2.
Individual source files and bundled components may carry their own notices;
those file-level and component-level notices remain authoritative. OpenResearchTools
changes to QEMU-derived code, DriverKit/VFIO integration, guest-driver packaging,
and Machine build/release integration are distributed as part of that GPL-covered
QEMU-derived source tree unless an individual file or patch hunk states a more
specific license.

DriverKit, VFIO, and QEMU integration work in vEGPU Machine builds on Scott J.
Goldman's `scottjg/qemu-vfio-apple` project. QEMU-side macOS SPICE/virgl
rendering work also adapts work from `utmapp/qemu` and `utmapp/virglrenderer`.
The app-side SPICE/GLib/GStreamer/ANGLE display runtime and embedded GUI
display integration are partially based on the main `utmapp/UTM` app work,
generated from the pinned UTM dependency recipe and the vEGPU patch stack.

The embedded chat UI and app-facing AI runtime controls are based on llama.cpp
server conventions, llama.cpp-compatible APIs, and the llama.cpp web UI
surface. The runtime/model router uses llama-swap-style request routing adapted
for configured macOS and VM runtimes, multiple model aliases, and sessions
detached from a single fixed `llama-server` process. The local proxy helper
uses a GOST-inspired TCP/UDP forwarding model for Mac-to-VM and VM-to-Mac
routes.

vEGPU and vEGPU Machine are not endorsed by, sponsored by, or affiliated with
Fabrice Bellard or the QEMU project, Scott J. Goldman, scottjg/qemu-vfio-apple,
UTM, utmapp/qemu, utmapp/virglrenderer, llama.cpp, llama-swap, GOST, TurboQuant,
or their maintainers.
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

System Integrity Protection must be disabled before installation. To disable
SIP on Apple Silicon, shut down, hold the power button until startup options
appear, open Options > Utilities > Terminal, run `csrutil disable`, restart,
and then run this installer again.
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
fi

if [ "$INCLUDE_MACHINE" = "1" ]; then
  cat > "$WORK/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>vEGPU</title>
  <options customize="always" require-scripts="true"/>
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

function sipDisabled() {
  var result = system.run("/usr/bin/csrutil", "status");
  var text = commandText(result);
  if (/disabled/i.test(text)) {
    return true;
  }
  my.result.title = "System Integrity Protection must be disabled";
  my.result.message = "vEGPU Machine uses an ad-hoc DriverKit host extension for PCIe/eGPU passthrough. Disable SIP from macOS Recovery with `csrutil disable`, restart, and run this installer again.";
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
  if (compareVersion(machinePayloadBuild, installedBuild) > 0) { return true; }
  return !driverInstalled();
}
  ]]></script>
  <welcome file="WELCOME.html" mime-type="text/html"/>
  <license file="LICENSE.txt" mime-type="text/plain"/>
  <conclusion file="CONCLUSION.txt" mime-type="text/plain"/>
  <choices-outline>
    <line choice="com.vegpu.install.app"/>
    <line choice="com.vegpu.install.machine"/>
  </choices-outline>
  <choice id="com.vegpu.install.app" title="vEGPU.app" description="Required main application: Apache-2.0 Swift/AppKit launcher, GUI, app-side SPICE display client, AI runtime controls, app notices, and app-side source archives." start_selected="true" start_enabled="false" start_visible="true">
    <pkg-ref id="com.vegpu.pkg.app"/>
  </choice>
  <choice id="com.vegpu.install.machine" title="vEGPU Machine.app and DriverKit host extension" description="Separate QEMU/VFIO/DriverKit runtime. Selected by default when Machine is missing, older, or the same version with no installed DriverKit extension. If selected, the installer refreshes Machine and the macOS DriverKit extension, then recommends a restart." start_selected="machineNeedsInstall()" start_enabled="true" start_visible="true">
    <pkg-ref id="com.vegpu.pkg.machine"/>
  </choice>
  <pkg-ref id="com.vegpu.pkg.app" version="$VERSION" onConclusion="none">vEGPU-app.pkg</pkg-ref>
  <pkg-ref id="com.vegpu.pkg.machine" version="$VERSION" onConclusion="RecommendRestart">vEGPU-machine.pkg</pkg-ref>
</installer-gui-script>
XML
else
  cat > "$WORK/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>vEGPU</title>
  <options customize="always" require-scripts="true"/>
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
  my.result.message = "vEGPU releases require SIP to be disabled because combined releases install an ad-hoc DriverKit host extension. Disable SIP from macOS Recovery with `csrutil disable`, restart, and run this installer again.";
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

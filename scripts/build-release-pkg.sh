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
    cat >> "$dir/preinstall" <<SCRIPT

VEGPU_NEW_MACHINE_BUILD="$machine_new_build"
VEGPU_NEW_MACHINE_SHORT_VERSION="$machine_new_short_version"
SCRIPT
    cat >> "$dir/preinstall" <<'SCRIPT'
VEGPU_INSTALLED_MACHINE="/Applications/vEGPU Machine.app"
VEGPU_MACHINE_EXECUTABLE="$VEGPU_INSTALLED_MACHINE/Contents/MacOS/vEGPU Machine"
VEGPU_DRIVER_ID="com.vegpu.machine.VFIOUserPCIDriver"
VEGPU_DRIVER_REFRESH_MARKER="/tmp/com.vegpu.machine.pkg.driver-refresh-needed"

rm -f "$VEGPU_DRIVER_REFRESH_MARKER"

run_as_console_user() {
  local console_user console_uid
  console_user="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)"
  if [ -z "$console_user" ] || [ "$console_user" = "root" ]; then
    "$@"
    return $?
  fi
  console_uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
  if [ -z "$console_uid" ]; then
    "$@"
    return $?
  fi
  /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" "$@"
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

version_gt() {
  /usr/bin/awk -v a="$1" -v b="$2" '
    BEGIN {
      n = split(a, av, /[^0-9]+/)
      m = split(b, bv, /[^0-9]+/)
      max = n > m ? n : m
      for (i = 1; i <= max; i++) {
        ai = av[i] == "" ? 0 : av[i] + 0
        bi = bv[i] == "" ? 0 : bv[i] + 0
        if (ai > bi) exit 0
        if (ai < bi) exit 1
      }
      exit 1
    }
  '
}

machine_payload_should_install() {
  local installed_info="$VEGPU_INSTALLED_MACHINE/Contents/Info.plist"
  [ -f "$installed_info" ] || return 0

  local installed_build installed_short
  installed_build="$(plist_value "$installed_info" CFBundleVersion)"
  installed_short="$(plist_value "$installed_info" CFBundleShortVersionString)"

  if version_gt "$VEGPU_NEW_MACHINE_SHORT_VERSION" "$installed_short"; then
    return 0
  fi
  if [ "$VEGPU_NEW_MACHINE_SHORT_VERSION" = "$installed_short" ] && version_gt "$VEGPU_NEW_MACHINE_BUILD" "$installed_build"; then
    return 0
  fi
  return 1
}

force_uninstall_driver() {
  /usr/bin/systemextensionsctl uninstall - "$VEGPU_DRIVER_ID"
}

if machine_payload_should_install; then
  touch "$VEGPU_DRIVER_REFRESH_MARKER"
  echo "vEGPU Machine update detected. Removing existing macOS driver before replacing the host app."
  if [ -x "$VEGPU_MACHINE_EXECUTABLE" ]; then
    if run_as_console_user "$VEGPU_MACHINE_EXECUTABLE" --driver-deactivate; then
      echo "Existing macOS driver deactivation request completed."
    else
      echo "Graceful macOS driver deactivation failed; attempting forced system extension uninstall." >&2
      force_uninstall_driver || echo "Forced macOS driver uninstall did not complete; continuing package replacement." >&2
    fi
  else
    echo "Existing vEGPU Machine executable is missing; attempting forced system extension uninstall."
    force_uninstall_driver || echo "Forced macOS driver uninstall did not complete; continuing package replacement." >&2
  fi
else
  echo "Installed vEGPU Machine is the same or newer; skipping driver refresh."
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
run_as_console_user() {
  local console_user console_uid
  console_user="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)"
  if [ -z "$console_user" ] || [ "$console_user" = "root" ]; then
    "$@"
    return $?
  fi
  console_uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
  if [ -z "$console_uid" ]; then
    "$@"
    return $?
  fi
  /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" "$@"
}

if [ ! -f "$VEGPU_DRIVER_REFRESH_MARKER" ]; then
  echo "vEGPU Machine driver refresh was not requested; leaving existing driver state unchanged."
elif [ -x "$VEGPU_MACHINE_EXECUTABLE" ]; then
  if run_as_console_user "$VEGPU_MACHINE_EXECUTABLE" --driver-activate; then
    echo "vEGPU Machine macOS driver activation request submitted."
  else
    echo "vEGPU Machine macOS driver activation request failed; open vEGPU Machine or run --driver-activate manually." >&2
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

cat > "$RESOURCES/WELCOME.txt" <<'TEXT'
vEGPU installs two related applications:

- vEGPU.app: the launcher, AppKit GUI, app-side SPICE display client, and AI runtime controls.
- vEGPU Machine.app: the DriverKit/VFIO/QEMU virtual machine runtime used by vEGPU.

More information:

- https://vegpu.com
- https://github.com/openresearchtools/vEGPU
- https://github.com/openresearchtools/vEGPU-machine

This installer requires SIP to be disabled before installation can continue.
TEXT

cat > "$RESOURCES/README.txt" <<'TEXT'
System Integrity Protection requirement
=======================================

vEGPU Machine uses an ad-hoc DriverKit host extension for PCIe/eGPU passthrough.
The installer will stop if System Integrity Protection is still enabled.

To disable SIP on Apple Silicon:

1. Shut down the Mac.
2. Hold the power button until startup options appear.
3. Open Options, then Utilities, then Terminal.
4. Run: csrutil disable
5. Restart macOS and run this installer again.

This has real security implications. Do not install vEGPU on a machine that
holds sensitive data unless you accept that tradeoff.

Licenses, notices, and source bundles
=====================================

After installation, licenses and notices are available from each installed
application's Help menu. The package also installs the corresponding source
tarballs/source bundles inside the application bundles for licensing
obligations.

For combined releases, the installer removes the old macOS DriverKit extension
before replacing vEGPU Machine.app when the package carries a newer Machine
build, submits a fresh driver activation request afterward, and recommends a
restart as the final installation step.

vEGPU follows the UTM and UTM-QEMU style split with a visible boundary:
vEGPU Machine owns the GPL DriverKit/QEMU/VM mechanics, while vEGPU owns the
launcher, GUI, app-side display client, and AI runtime layers. GPL-derived
QEMU code stays on the Machine side; the app-side runtime stays separate.
TEXT

cat > "$RESOURCES/LICENSE.txt" <<'TEXT'
vEGPU Installer Notice
======================

This package installs two related projects/applications:

1. vEGPU.app
   Launcher, Swift/AppKit GUI, app-side SPICE display client, and AI runtime
   controls.

   Repository:
   https://github.com/openresearchtools/vEGPU

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

For combined releases, the installer removes the old macOS DriverKit extension
before replacing vEGPU Machine.app when the package carries a newer Machine
build, submits a fresh driver activation request after installation, and then
offers the normal macOS restart choice so the driver state is clean.

Architecture and license boundary
=================================

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
Goldman's `scottjg/qemu-vfio-apple` project. The QEMU-side macOS SPICE/virgl
rendering runtime also adapts work from `utmapp/qemu` and `utmapp/virglrenderer`.
The app-side SPICE/GLib/GStreamer/ANGLE display runtime is generated from the
pinned UTM dependency recipe and vEGPU patch stack.

vEGPU and vEGPU Machine are not endorsed by, sponsored by, or affiliated with
Fabrice Bellard or the QEMU project, Scott J. Goldman, scottjg/qemu-vfio-apple,
UTM, utmapp/qemu, utmapp/virglrenderer, or their maintainers.
TEXT
if [ "$INCLUDE_MACHINE" != "1" ]; then
  cat > "$RESOURCES/WELCOME.txt" <<'TEXT'
vEGPU installs vEGPU.app.

Combined public releases also install vEGPU Machine.app, the DriverKit/VFIO/QEMU
virtual machine runtime used by vEGPU.

More information:

- https://vegpu.com
- https://github.com/openresearchtools/vEGPU
- https://github.com/openresearchtools/vEGPU-machine

This installer requires SIP to be disabled before installation can continue.
TEXT

  cat > "$RESOURCES/README.txt" <<'TEXT'
System Integrity Protection requirement
=======================================

vEGPU releases require System Integrity Protection to be disabled before
installation. Combined releases install vEGPU Machine.app, which uses an
ad-hoc DriverKit host extension for PCIe/eGPU passthrough.

To disable SIP on Apple Silicon:

1. Shut down the Mac.
2. Hold the power button until startup options appear.
3. Open Options, then Utilities, then Terminal.
4. Run: csrutil disable
5. Restart macOS and run this installer again.

Licenses, notices, and source bundles are available from the installed app Help
menu. Combined releases also include vEGPU Machine notices/source bundles inside
vEGPU Machine.app.
TEXT

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
  <options customize="never" require-scripts="true"/>
  <script><![CDATA[
var machinePayloadVersion = "$MACHINE_NEW_SHORT_VERSION";
var machinePayloadBuild = "$MACHINE_NEW_BUILD";

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
  ]]></script>
  <welcome file="WELCOME.txt" mime-type="text/plain"/>
  <readme file="README.txt" mime-type="text/plain"/>
  <license file="LICENSE.txt" mime-type="text/plain"/>
  <choices-outline>
    <line choice="com.vegpu.install.app"/>
    <line choice="com.vegpu.install.machine"/>
  </choices-outline>
  <choice id="com.vegpu.install.app" title="vEGPU" start_selected="true" start_visible="false">
    <pkg-ref id="com.vegpu.pkg.app"/>
  </choice>
  <choice id="com.vegpu.install.machine" title="vEGPU Machine" start_selected="machineNeedsInstall()" start_visible="false">
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
  <options customize="never" require-scripts="true"/>
  <welcome file="WELCOME.txt" mime-type="text/plain"/>
  <readme file="README.txt" mime-type="text/plain"/>
  <license file="LICENSE.txt" mime-type="text/plain"/>
  <choices-outline>
    <line choice="com.vegpu.install"/>
  </choices-outline>
  <choice id="com.vegpu.install" title="vEGPU">
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

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${VERSION:-0.1.0}"
ARCH="${ARCH:-arm64}"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pegpu-build"
BUILD_DIR="${BUILD_DIR:-$DEFAULT_BUILD_ROOT/scaling-app-deb}"
PKG_DIR="$BUILD_DIR/pegpu-scaling_${VERSION}_${ARCH}"
OUT_DIR="$BUILD_DIR/out"

rm -rf "$PKG_DIR" "$OUT_DIR"
mkdir -p "$PKG_DIR/DEBIAN" "$OUT_DIR"

install_file() {
  local mode="$1" source="$2" target="$3"
  install -d "$(dirname "$target")"
  install -m "$mode" "$source" "$target"
}

install_file 0755 "$ROOT/bin/pegpu-scaling" "$PKG_DIR/usr/bin/pegpu-scaling"
install_file 0644 "$ROOT/src/pegpu_scaling.py" "$PKG_DIR/usr/lib/pegpu-scaling/pegpu_scaling.py"
install_file 0644 "$ROOT/share/applications/pegpu-scaling.desktop" "$PKG_DIR/usr/share/applications/pegpu-scaling.desktop"
install_file 0644 "$ROOT/share/icons/hicolor/scalable/apps/pegpu-scaling.svg" "$PKG_DIR/usr/share/icons/hicolor/scalable/apps/pegpu-scaling.svg"
install -d "$PKG_DIR/usr/share/doc/pegpu-scaling"
cat >"$PKG_DIR/usr/share/doc/pegpu-scaling/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: pegpu-scaling
Source: https://github.com/openresearchtools/PEGPU

Files: *
Copyright: 2026 OpenResearchTools
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.

Files: debian/*
Copyright: 2026 OpenResearchTools
License: MIT
EOF

cat >"$PKG_DIR/DEBIAN/control" <<EOF
Package: pegpu-scaling
Version: $VERSION
Section: x11
Priority: optional
Architecture: $ARCH
Maintainer: PEGPU <support@pegpu.local>
Depends: python3, python3-gi, gir1.2-gtk-3.0, libglib2.0-bin, xfconf, x11-xserver-utils
Description: Sharp XFCE session scaling helper for PEGPU guests
 Provides a GTK app and CLI for applying coordinated XFCE sizing
 settings without changing wallpaper, branding, or taskbar behavior.
EOF

cat >"$PKG_DIR/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
rm -f /etc/xdg/autostart/pegpu-scaling-reapply.desktop
if getent passwd pegpu >/dev/null 2>&1; then
  home="$(getent passwd pegpu | cut -d: -f6)"
  if [ -n "$home" ]; then
    desktop_file="$home/Desktop/pegpu-scaling.desktop"
    install -d -o pegpu -g pegpu "$home/Desktop"
    install -o pegpu -g pegpu -m 0755 /usr/share/applications/pegpu-scaling.desktop "$desktop_file"
    install -d -o pegpu -g pegpu "$home/.local/share/gvfs-metadata"
    chown pegpu:pegpu "$home/.local" "$home/.local/share" >/dev/null 2>&1 || true
    if command -v gio >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
      checksum="$(sha256sum "$desktop_file" | awk '{ print $1 }')"
      uid="$(id -u pegpu 2>/dev/null || true)"
      bus="/run/user/$uid/bus"
      if [ -n "$uid" ] && [ -S "$bus" ]; then
        runuser -u pegpu -- env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
          gio set -t string "$desktop_file" metadata::xfce-exe-checksum "$checksum" >/dev/null 2>&1 || true
      elif command -v dbus-run-session >/dev/null 2>&1; then
        runuser -u pegpu -- dbus-run-session \
          gio set -t string "$desktop_file" metadata::xfce-exe-checksum "$checksum" >/dev/null 2>&1 || true
      else
        runuser -u pegpu -- \
          gio set -t string "$desktop_file" metadata::xfce-exe-checksum "$checksum" >/dev/null 2>&1 || true
      fi
    fi
  fi
fi
EOF
chmod 0755 "$PKG_DIR/DEBIAN/postinst"

dpkg-deb --build --root-owner-group "$PKG_DIR" "$OUT_DIR/pegpu-scaling_${VERSION}_${ARCH}.deb"
printf '%s\n' "$OUT_DIR/pegpu-scaling_${VERSION}_${ARCH}.deb"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${VERSION:-0.1.0}"
ARCH="${ARCH:-arm64}"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pegpu-build"
BUILD_DIR="${BUILD_DIR:-$DEFAULT_BUILD_ROOT/performance-app-deb}"
PKG_DIR="$BUILD_DIR/pegpu-performance_${VERSION}_${ARCH}"
OUT_DIR="$BUILD_DIR/out"

rm -rf "$PKG_DIR" "$OUT_DIR"
mkdir -p "$PKG_DIR/DEBIAN" "$OUT_DIR"

install_file() {
  local mode="$1" source="$2" target="$3"
  install -d "$(dirname "$target")"
  install -m "$mode" "$source" "$target"
}

install_file 0755 "$ROOT/bin/pegpu-performance" "$PKG_DIR/usr/bin/pegpu-performance"
install_file 0644 "$ROOT/src/pegpu_performance.py" "$PKG_DIR/usr/lib/pegpu-performance/pegpu_performance.py"
install_file 0644 "$ROOT/share/applications/pegpu-performance.desktop" "$PKG_DIR/usr/share/applications/pegpu-performance.desktop"
for size in 256 512 1024; do
  source="$ROOT/share/icons/hicolor/${size}x${size}/apps/pegpu-performance.png"
  [ -f "$source" ] || continue
  install_file 0644 "$source" "$PKG_DIR/usr/share/icons/hicolor/${size}x${size}/apps/pegpu-performance.png"
done
if [ -f "$ROOT/share/icons/hicolor/scalable/apps/pegpu-performance.svg" ]; then
  install_file 0644 "$ROOT/share/icons/hicolor/scalable/apps/pegpu-performance.svg" "$PKG_DIR/usr/share/icons/hicolor/scalable/apps/pegpu-performance.svg"
fi
install_file 0644 "$ROOT/share/icons/source/pegpu-performance.png" "$PKG_DIR/usr/share/pegpu-performance/pegpu-performance.png"

install -d "$PKG_DIR/etc/sudoers.d"
cat >"$PKG_DIR/etc/sudoers.d/90-pegpu-performance" <<'EOF'
pegpu ALL=(root) NOPASSWD: /usr/sbin/apple-dma-config set --coalescing *, /usr/sbin/apple-dma-config reset
EOF
chmod 0440 "$PKG_DIR/etc/sudoers.d/90-pegpu-performance"

install -d "$PKG_DIR/usr/share/doc/pegpu-performance"
cat >"$PKG_DIR/usr/share/doc/pegpu-performance/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: pegpu-performance
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
Package: pegpu-performance
Version: $VERSION
Section: x11
Priority: optional
Architecture: $ARCH
Maintainer: PEGPU <support@pegpu.local>
Depends: python3, python3-gi, gir1.2-gtk-3.0, libglib2.0-bin, sudo
Description: DMA coalescing performance helper for PEGPU guests
 Provides a GTK app and CLI for selecting the Apple DMA coalescing
 window used by the guest-side apple_dma driver.
EOF

cat >"$PKG_DIR/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -e
install -d /etc/sudoers.d
if [ ! -f /etc/sudoers.d/90-pegpu-performance ]; then
  cat >/etc/sudoers.d/90-pegpu-performance <<'SUDOERS'
pegpu ALL=(root) NOPASSWD: /usr/sbin/apple-dma-config set --coalescing *, /usr/sbin/apple-dma-config reset
SUDOERS
fi
chmod 0440 /etc/sudoers.d/90-pegpu-performance
if command -v visudo >/dev/null 2>&1; then
  visudo -cf /etc/sudoers.d/90-pegpu-performance >/dev/null 2>&1 || rm -f /etc/sudoers.d/90-pegpu-performance
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
if getent passwd pegpu >/dev/null 2>&1; then
  home="$(getent passwd pegpu | cut -d: -f6)"
  if [ -n "$home" ]; then
    desktop_file="$home/Desktop/pegpu-performance.desktop"
    install -d -o pegpu -g pegpu "$home/Desktop"
    install -o pegpu -g pegpu -m 0755 /usr/share/applications/pegpu-performance.desktop "$desktop_file"
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

dpkg-deb --build --root-owner-group "$PKG_DIR" "$OUT_DIR/pegpu-performance_${VERSION}_${ARCH}.deb"
printf '%s\n' "$OUT_DIR/pegpu-performance_${VERSION}_${ARCH}.deb"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"

install_file() {
  local mode="$1" source="$2" target="$3"
  install -d "$(dirname "$target")"
  install -m "$mode" "$source" "$target"
}

trust_desktop_file() {
  local user="$1" file="$2" uid bus checksum home
  [ -f "$file" ] || return 0
  chmod 0755 "$file" >/dev/null 2>&1 || true
  command -v gio >/dev/null 2>&1 || return 0
  command -v sha256sum >/dev/null 2>&1 || return 0
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  if [ -n "$home" ]; then
    install -d -o "$user" -g "$user" "$home/.local/share/gvfs-metadata"
    chown "$user:$user" "$home/.local" "$home/.local/share" >/dev/null 2>&1 || true
  fi
  checksum="$(sha256sum "$file" | awk '{ print $1 }')"
  [ -n "$checksum" ] || return 0
  uid="$(id -u "$user" 2>/dev/null || true)"
  bus="/run/user/$uid/bus"
  if [ -n "$uid" ] && [ -S "$bus" ]; then
    runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
      gio set -t string "$file" metadata::xfce-exe-checksum "$checksum" >/dev/null 2>&1 || true
  elif command -v dbus-run-session >/dev/null 2>&1; then
    runuser -u "$user" -- dbus-run-session \
      gio set -t string "$file" metadata::xfce-exe-checksum "$checksum" >/dev/null 2>&1 || true
  else
    runuser -u "$user" -- \
      gio set -t string "$file" metadata::xfce-exe-checksum "$checksum" >/dev/null 2>&1 || true
  fi
}

if [ "$(id -u)" -ne 0 ]; then
  printf 'install.sh must be run as root. Try: sudo %s\n' "$0" >&2
  exit 1
fi

if [ "${VEGPU_SCALING_SKIP_DEPS:-0}" != "1" ] && command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    gir1.2-gtk-3.0 \
    libglib2.0-bin \
    python3 \
    python3-gi \
    xfconf \
    x11-xserver-utils
fi

install_file 0755 "$ROOT/bin/vegpu-scaling" "$PREFIX/bin/vegpu-scaling"
install_file 0644 "$ROOT/src/vegpu_scaling.py" "$PREFIX/lib/vegpu-scaling/vegpu_scaling.py"
install_file 0644 "$ROOT/share/applications/vegpu-scaling.desktop" "$PREFIX/share/applications/vegpu-scaling.desktop"
install_file 0644 "$ROOT/share/icons/hicolor/scalable/apps/vegpu-scaling.svg" "$PREFIX/share/icons/hicolor/scalable/apps/vegpu-scaling.svg"
rm -f /etc/xdg/autostart/vegpu-scaling-reapply.desktop

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$PREFIX/share/applications" >/dev/null 2>&1 || true
fi

DESKTOP_USER="${VEGPU_SCALING_DESKTOP_USER:-vegpu}"
if getent passwd "$DESKTOP_USER" >/dev/null 2>&1; then
  DESKTOP_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
  if [ -n "$DESKTOP_HOME" ]; then
    desktop_file="$DESKTOP_HOME/Desktop/vegpu-scaling.desktop"
    install -d -o "$DESKTOP_USER" -g "$DESKTOP_USER" "$DESKTOP_HOME/Desktop"
    install -o "$DESKTOP_USER" -g "$DESKTOP_USER" -m 0755 \
      "$PREFIX/share/applications/vegpu-scaling.desktop" \
      "$desktop_file"
    trust_desktop_file "$DESKTOP_USER" "$desktop_file"
  fi
fi

printf 'Installed vegpu-scaling to %s/bin/vegpu-scaling\n' "$PREFIX"

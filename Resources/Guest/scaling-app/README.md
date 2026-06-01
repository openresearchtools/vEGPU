# vEGPU Scaling

Standalone XFCE session-scaling app for Debian ARM guests.

It changes only sizing-related XFCE settings. It does not change wallpaper,
menu logos, icon themes, taskbar plugin behavior, or app branding.
XFWM-decorated native window titlebars are scaled with the nearest installed
HDPI/XHDPI decoration theme; stale title-font overrides are removed.

The install script adds the app menu entry, an original `vegpu-scaling` icon,
the per-session autostart reapply entry, and a `vegpu` desktop launcher.

The helper is vEGPU-owned MIT-licensed code. The Debian package records that in
`/usr/share/doc/vegpu-scaling/copyright` and depends on system Python, GTK,
X11, and XFCE packages instead of bundling those projects.

## Commands

```sh
vegpu-scaling --gui
vegpu-scaling list --json
vegpu-scaling get --json
vegpu-scaling set --scale 1.25
vegpu-scaling reset
vegpu-scaling reapply
vegpu-scaling --display :0 set --scale 2
```

Supported scales are `1`, `1.25`, `1.50`, `1.75`, `2`, `2.25`, `2.50`,
`2.75`, and `3`.

Scale `1` removes the app-owned sizing overrides and returns the session to
native/default sizing. Captured first-run values and saved per-`DISPLAY` state
are stored in `~/.config/vegpu-scaling/`.

## Install

Local install:

```sh
sudo ./install.sh
```

Build a Debian package:

```sh
BUILD_DIR="${TMPDIR:-/tmp}/vegpu-build/scaling-app-deb" ./build-deb.sh
sudo apt install "${TMPDIR:-/tmp}/vegpu-build/scaling-app-deb/out/vegpu-scaling_0.1.0_arm64.deb"
```

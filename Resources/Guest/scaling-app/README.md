# PEGPU Scaling

Standalone XFCE session-scaling app for Debian ARM guests.

It changes only sizing-related XFCE settings. It does not change wallpaper,
menu logos, icon themes, taskbar plugin behavior, or app branding.
XFWM-decorated native window titlebars are scaled with the nearest installed
HDPI/XHDPI decoration theme; stale title-font overrides are removed.

The install script adds the app menu entry, an original `pegpu-scaling` icon,
the per-session autostart reapply entry, and a `pegpu` desktop launcher.

The helper is PEGPU-owned MIT-licensed code. The Debian package records that in
`/usr/share/doc/pegpu-scaling/copyright` and depends on system Python, GTK,
X11, and XFCE packages instead of bundling those projects.

## Commands

```sh
pegpu-scaling --gui
pegpu-scaling list --json
pegpu-scaling get --json
pegpu-scaling set --scale 1.25
pegpu-scaling reset
pegpu-scaling reapply
pegpu-scaling --display :0 set --scale 2
```

Supported scales are `1`, `1.25`, `1.50`, `1.75`, `2`, `2.25`, `2.50`,
`2.75`, and `3`.

Scale `1` removes the app-owned sizing overrides and returns the session to
native/default sizing. Captured first-run values and saved per-`DISPLAY` state
are stored in `~/.config/pegpu-scaling/`.

## Install

Local install:

```sh
sudo ./install.sh
```

Build a Debian package:

```sh
BUILD_DIR="${TMPDIR:-/tmp}/pegpu-build/scaling-app-deb" ./build-deb.sh
sudo apt install "${TMPDIR:-/tmp}/pegpu-build/scaling-app-deb/out/pegpu-scaling_0.1.0_arm64.deb"
```

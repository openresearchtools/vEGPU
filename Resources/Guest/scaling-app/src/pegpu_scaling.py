#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


SUPPORTED_SCALES = ("1", "1.25", "1.50", "1.75", "2", "2.25", "2.50", "2.75", "3")
BASE_DPI = 96
APP_ID = "com.pegpu.scaling"
APP_ICON_NAME = "pegpu-scaling"
TITLE_FONT_FAMILY = "Sans Bold"
LOCK_WAIT_SECONDS = 2.0


@dataclass(frozen=True)
class ScaleProfile:
    gtk_scale: int
    dpi: int
    cursor: int
    gtk_menu_icon: int
    gtk_large_toolbar_icon: int
    gtk_dnd_icon: int
    gtk_dialog_icon: int
    panel: int
    desktop_icon: int
    title_points: int


SCALE_PROFILES: dict[str, ScaleProfile] = {
    "1": ScaleProfile(1, 96, 24, 20, 28, 40, 48, 32, 48, 9),
    "1.25": ScaleProfile(1, 120, 30, 25, 35, 50, 60, 40, 60, 10),
    "1.50": ScaleProfile(1, 144, 36, 30, 42, 60, 72, 48, 72, 11),
    "1.75": ScaleProfile(1, 168, 42, 35, 49, 70, 84, 56, 84, 11),
    "2": ScaleProfile(2, 96, 48, 20, 28, 40, 48, 40, 48, 12),
    "2.25": ScaleProfile(2, 108, 54, 23, 32, 45, 54, 45, 54, 13),
    "2.50": ScaleProfile(2, 120, 60, 25, 35, 50, 60, 50, 60, 14),
    "2.75": ScaleProfile(2, 132, 66, 28, 39, 55, 66, 55, 66, 15),
    "3": ScaleProfile(3, 96, 72, 20, 28, 40, 48, 40, 48, 16),
}


@dataclass(frozen=True)
class XfconfSetting:
    channel: str
    path: str
    value_type: str


@dataclass(frozen=True)
class PlannedSetting:
    setting: XfconfSetting
    value: str


OWNED_SETTINGS: tuple[XfconfSetting, ...] = (
    XfconfSetting("xsettings", "/Xft/DPI", "int"),
    XfconfSetting("xsettings", "/Gdk/WindowScalingFactor", "int"),
    XfconfSetting("xsettings", "/Gtk/CursorThemeSize", "int"),
    XfconfSetting("xsettings", "/Gtk/IconSizes", "string"),
    XfconfSetting("xsettings", "/Gtk/MenuImages", "bool"),
    XfconfSetting("xsettings", "/Gtk/ButtonImages", "bool"),
    XfconfSetting("xfce4-panel", "/panels/panel-1/size", "uint"),
    XfconfSetting("xfce4-panel", "/panels/panel-1/row-size", "uint"),
    XfconfSetting("xfce4-panel", "/panels/panel-1/nrows", "uint"),
    XfconfSetting("xfce4-panel", "/panels/panel-1/mode", "uint"),
    XfconfSetting("xfwm4", "/general/theme", "string"),
    XfconfSetting("xfwm4", "/general/title_font", "string"),
    XfconfSetting("xfce4-desktop", "/desktop-icons/icon-size", "uint"),
    XfconfSetting("xfce4-desktop", "/desktop-icons/font-size", "uint"),
)


def config_dir() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME")
    if base:
        return Path(base) / "pegpu-scaling"
    return Path.home() / ".config" / "pegpu-scaling"


def state_path() -> Path:
    return config_dir() / "state.json"


def lock_path() -> Path:
    return config_dir() / "apply.lock"


@contextmanager
def scale_transaction(wait_seconds: float = LOCK_WAIT_SECONDS) -> Iterable[None]:
    path = lock_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as lock_file:
        deadline = time.monotonic() + wait_seconds
        while True:
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError as exc:
                if time.monotonic() >= deadline:
                    raise RuntimeError("PEGPU Scaling is already applying changes; try again in a moment") from exc
                time.sleep(0.05)
        try:
            yield
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def display_name(display: str | None = None) -> str:
    return (display or os.environ.get("DISPLAY") or "").strip()


def require_display(display: str | None = None) -> str:
    resolved = display_name(display)
    if not resolved:
        raise RuntimeError("DISPLAY is not set; run inside an X11 session or pass --display")
    return resolved


def display_key(display: str | None = None) -> str:
    raw = require_display(display)
    key = re.sub(r"[^A-Za-z0-9_.-]+", "_", raw).strip("_")
    return key or "default"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def displays_equivalent(left: str | None, right: str | None) -> bool:
    def variants(value: str | None) -> set[str]:
        raw = (value or "").strip()
        if not raw:
            return set()
        names = {raw}
        if raw.endswith(".0"):
            names.add(raw[:-2])
        elif re.fullmatch(r":[0-9]+", raw):
            names.add(f"{raw}.0")
        return names

    return bool(variants(left) & variants(right))


def process_environ(pid: Path) -> dict[str, str] | None:
    try:
        raw = (pid / "environ").read_bytes()
    except OSError:
        return None
    env: dict[str, str] = {}
    for item in raw.split(b"\0"):
        if not item or b"=" not in item:
            continue
        key, value = item.split(b"=", 1)
        env[key.decode(errors="ignore")] = value.decode(errors="ignore")
    return env


def process_env_for_command(command: str, display: str | None) -> dict[str, str] | None:
    for pid in Path("/proc").iterdir():
        if not pid.name.isdigit():
            continue
        try:
            comm = (pid / "comm").read_text().strip()
        except OSError:
            continue
        if comm != command:
            continue
        env = process_environ(pid)
        if env is not None and displays_equivalent(env.get("DISPLAY"), display):
            return env
    return None


def session_env(display: str | None = None) -> dict[str, str]:
    env = os.environ.copy()
    env["DISPLAY"] = require_display(display)
    if "DBUS_SESSION_BUS_ADDRESS" not in env:
        bus = Path(f"/run/user/{os.getuid()}/bus")
        if bus.exists():
            env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path={bus}"
    session = process_env_for_command("xfce4-session", env.get("DISPLAY"))
    if session:
        for key in ("XAUTHORITY", "SESSION_MANAGER", "DBUS_SESSION_BUS_ADDRESS"):
            if session.get(key):
                env.setdefault(key, session[key])
    return env


def run_command(
    args: list[str],
    env: dict[str, str] | None = None,
    check: bool = False,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        env=env,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


def xrdb_resources(env: dict[str, str]) -> dict[str, str] | None:
    result = run_command(["xrdb", "-query"], env=env)
    if result.returncode != 0:
        return None
    resources: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        name = name.strip()
        if name:
            resources[name] = value.strip()
    return resources


def xrdb_load(resources: dict[str, str], env: dict[str, str]) -> None:
    data = "".join(f"{name}: {value}\n" for name, value in resources.items())
    run_command(["xrdb", "-load"], env=env, input_text=data)


def apply_xcursor_size(size: int, env: dict[str, str]) -> bool:
    resources = xrdb_resources(env)
    if resources is None:
        return False
    value = str(size)
    if resources.get("Xcursor.size") == value:
        return False
    resources["Xcursor.size"] = value
    xrdb_load(resources, env)
    return True


def load_state() -> dict[str, Any]:
    path = state_path()
    if not path.exists():
        return {"version": 1, "sessions": {}}
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        return {"version": 1, "sessions": {}}
    if not isinstance(data, dict):
        return {"version": 1, "sessions": {}}
    data.setdefault("version", 1)
    data.setdefault("sessions", {})
    return data


def save_state(data: dict[str, Any]) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def xfconf_set(setting: XfconfSetting, value: str, env: dict[str, str]) -> None:
    base = ["xfconf-query", "-c", setting.channel, "-p", setting.path]
    result = run_command(base + ["-s", value], env=env)
    if result.returncode == 0:
        return
    created = run_command(base + ["-n", "-t", setting.value_type, "-s", value], env=env)
    if created.returncode != 0:
        raise RuntimeError(created.stderr.strip() or f"failed to set {setting.channel} {setting.path}")


def xfconf_remove(setting: XfconfSetting, env: dict[str, str]) -> None:
    run_command(["xfconf-query", "-c", setting.channel, "-p", setting.path, "-r"], env=env)


def xfconf_get(setting: XfconfSetting, env: dict[str, str]) -> str | None:
    result = run_command(["xfconf-query", "-c", setting.channel, "-p", setting.path], env=env)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def xfconf_values_equal(setting: XfconfSetting, current: str | None, expected: str) -> bool:
    if current is None:
        return False
    if setting.value_type == "bool":
        return current.lower() == expected.lower()
    return current == expected


def xfconf_set_if_needed(setting: XfconfSetting, value: str, env: dict[str, str]) -> bool:
    if xfconf_values_equal(setting, xfconf_get(setting, env), value):
        return False
    xfconf_set(setting, value, env)
    return True


def xfconf_remove_if_present(setting: XfconfSetting, env: dict[str, str]) -> bool:
    if xfconf_get(setting, env) is None:
        return False
    xfconf_remove(setting, env)
    return True


def normalize_scale(raw: str | float | int) -> str:
    text = str(raw).strip()
    try:
        value = float(text)
    except ValueError as exc:
        raise ValueError(f"unsupported scale: {raw}") from exc
    for label in SUPPORTED_SCALES:
        if abs(float(label) - value) < 0.001:
            return label
    raise ValueError(f"unsupported scale: {raw}")


def scale_number(label: str) -> float:
    return float(normalize_scale(label))


def scale_profile(label: str) -> ScaleProfile:
    return SCALE_PROFILES[normalize_scale(label)]


def integer_gtk_scale(scale: float) -> int:
    return scale_profile(str(scale)).gtk_scale


def cursor_size_for_scale(scale: float) -> int:
    return scale_profile(str(scale)).cursor


def gtk_icon_sizes(profile: ScaleProfile) -> str:
    sizes = {
        "gtk-menu": profile.gtk_menu_icon,
        "gtk-button": profile.gtk_menu_icon,
        "gtk-small-toolbar": profile.gtk_menu_icon,
        "gtk-large-toolbar": profile.gtk_large_toolbar_icon,
        "gtk-dnd": profile.gtk_dnd_icon,
        "gtk-dialog": profile.gtk_dialog_icon,
    }
    return ":".join(f"{name}={value},{value}" for name, value in sizes.items())


def installed_xfwm_theme(scale: float, roots: Iterable[Path] | None = None) -> str | None:
    roots = tuple(roots or (Path("/usr/share/themes"), Path.home() / ".themes"))
    if scale >= 1.75:
        candidates = ("Default-xhdpi", "Default-hdpi")
    elif scale >= 1.25:
        candidates = ("Default-hdpi", "Default-xhdpi")
    else:
        candidates = ("Default",)
    for candidate in candidates:
        if any((root / candidate / "xfwm4").is_dir() for root in roots):
            return candidate
    return "Default"


def title_font_for_scale(scale_label: str) -> str | None:
    return f"{TITLE_FONT_FAMILY} {scale_profile(scale_label).title_points}"


def build_scale_plan(scale_label: str, theme_roots: Iterable[Path] | None = None) -> list[PlannedSetting]:
    scale = scale_number(scale_label)
    profile = scale_profile(scale_label)

    settings = {f"{s.channel}:{s.path}": s for s in OWNED_SETTINGS}

    plan = [
        PlannedSetting(settings["xsettings:/Xft/DPI"], str(profile.dpi)),
        PlannedSetting(settings["xsettings:/Gdk/WindowScalingFactor"], str(profile.gtk_scale)),
        PlannedSetting(settings["xsettings:/Gtk/CursorThemeSize"], str(profile.cursor)),
        PlannedSetting(settings["xsettings:/Gtk/IconSizes"], gtk_icon_sizes(profile)),
        PlannedSetting(settings["xsettings:/Gtk/MenuImages"], "true"),
        PlannedSetting(settings["xsettings:/Gtk/ButtonImages"], "true"),
        PlannedSetting(settings["xfce4-panel:/panels/panel-1/size"], str(profile.panel)),
        PlannedSetting(settings["xfce4-panel:/panels/panel-1/row-size"], str(profile.panel)),
        PlannedSetting(settings["xfce4-panel:/panels/panel-1/nrows"], "1"),
        PlannedSetting(settings["xfce4-panel:/panels/panel-1/mode"], "0"),
        PlannedSetting(settings["xfce4-desktop:/desktop-icons/icon-size"], str(profile.desktop_icon)),
    ]
    theme = installed_xfwm_theme(scale, theme_roots)
    if theme:
        plan.append(PlannedSetting(settings["xfwm4:/general/theme"], theme))
    title_font = title_font_for_scale(scale_label)
    if title_font:
        plan.append(PlannedSetting(settings["xfwm4:/general/title_font"], title_font))
    return plan


def refresh_window_manager(env: dict[str, str]) -> None:
    run_command(["sh", "-lc", "nohup xfwm4 --replace >/dev/null 2>&1 &"], env=env)


def update_state(display: str | None, scale_label: str) -> None:
    data = load_state()
    key = display_key(display)
    data.setdefault("sessions", {})[key] = {
        "display": display_name(display),
        "scale": normalize_scale(scale_label),
        "updatedAt": now_iso(),
    }
    save_state(data)


def saved_scale(display: str | None) -> str:
    data = load_state()
    session = data.get("sessions", {}).get(display_key(display), {})
    try:
        return normalize_scale(session.get("scale", "1"))
    except ValueError:
        return "1"


def apply_scale_unlocked(scale_label: str, display: str | None = None, quiet: bool = False) -> str:
    scale_label = normalize_scale(scale_label)
    env = session_env(display)
    changed = xfconf_remove_if_present(XfconfSetting("xfce4-desktop", "/desktop-icons/font-size", "uint"), env)
    for planned in build_scale_plan(scale_label):
        changed = xfconf_set_if_needed(planned.setting, planned.value, env) or changed
    changed = apply_xcursor_size(cursor_size_for_scale(scale_number(scale_label)), env) or changed
    update_state(display, scale_label)
    if changed:
        refresh_window_manager(env)
    if not quiet:
        print(f"Applied scale {scale_label} on DISPLAY={display_name(display)}")
    return scale_label


def apply_scale(scale_label: str, display: str | None = None, quiet: bool = False) -> str:
    with scale_transaction():
        return apply_scale_unlocked(scale_label, display, quiet)


def reapply_saved_scale(display: str | None = None) -> str:
    with scale_transaction():
        return apply_scale_unlocked(saved_scale(display), display, quiet=True)


def xrandr_outputs(display: str | None = None) -> list[dict[str, Any]]:
    env = session_env(display)
    result = run_command(["xrandr", "--listmonitors"], env=env)
    if result.returncode != 0:
        return []
    outputs: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("Monitors:"):
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        outputs.append({"index": parts[0].rstrip(":"), "geometry": parts[2], "name": parts[-1], "primary": "*" in parts[1]})
    return outputs


def command_list(args: argparse.Namespace) -> int:
    display = require_display(args.display)
    payload = {
        "display": display,
        "scales": list(SUPPORTED_SCALES),
        "outputs": xrandr_outputs(display),
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(" ".join(SUPPORTED_SCALES))
    return 0


def command_get(args: argparse.Namespace) -> int:
    display = require_display(args.display)
    payload = {
        "display": display,
        "scale": saved_scale(display),
        "outputs": xrandr_outputs(display),
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(payload["scale"])
    return 0


def command_set(args: argparse.Namespace) -> int:
    apply_scale(args.scale, args.display, quiet=args.quiet)
    return 0


def command_reset(args: argparse.Namespace) -> int:
    apply_scale("1", args.display, quiet=args.quiet)
    return 0


def command_reapply(args: argparse.Namespace) -> int:
    reapply_saved_scale(args.display)
    return 0


def run_gui(args: argparse.Namespace) -> int:
    try:
        import gi

        gi.require_version("Gtk", "3.0")
        gi.require_version("Gdk", "3.0")
        from gi.repository import Gdk, GLib, Gtk, Pango
    except Exception as exc:
        print(f"GTK3 Python bindings are unavailable: {exc}", file=sys.stderr)
        return 1

    def add_css() -> None:
        provider = Gtk.CssProvider()
        provider.load_from_data(
            b"""
            .pegpu-window {
              background: @theme_bg_color;
            }
            .pegpu-title {
              font-weight: 700;
              font-size: 15px;
            }
            .pegpu-muted {
              color: alpha(@theme_fg_color, 0.68);
            }
            .pegpu-scale-card {
              border: 1px solid alpha(@theme_fg_color, 0.16);
              border-radius: 8px;
              background: alpha(@theme_base_color, 0.72);
              padding: 8px;
            }
            .pegpu-scale-button {
              min-width: 64px;
              min-height: 32px;
              padding: 4px 8px;
              font-weight: 700;
            }
            .pegpu-scale-button:checked {
              background: #2f6fed;
              border-color: #2458bd;
              color: #ffffff;
            }
            .pegpu-footer {
              border-top: 1px solid alpha(@theme_fg_color, 0.12);
              padding-top: 10px;
            }
            """
        )
        screen = Gdk.Screen.get_default()
        if screen is not None:
            Gtk.StyleContext.add_provider_for_screen(screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def set_margins(widget: Any, value: int) -> None:
        widget.set_margin_top(value)
        widget.set_margin_bottom(value)
        widget.set_margin_start(value)
        widget.set_margin_end(value)

    add_css()

    class ScalingWindow(Gtk.Window):
        def __init__(self) -> None:
            super().__init__(title="PEGPU Scaling")
            self.set_icon_name(APP_ICON_NAME)
            self.set_default_size(420, 300)
            self.set_resizable(False)
            self.connect("destroy", Gtk.main_quit)
            self.get_style_context().add_class("pegpu-window")
            self.scale_buttons: dict[str, Gtk.ToggleButton] = {}
            self.selected_scale = saved_scale(args.display)
            self.busy = False

            outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            set_margins(outer, 16)
            self.add(outer)

            header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            outer.pack_start(header, False, False, 0)

            icon = Gtk.Image.new_from_icon_name(APP_ICON_NAME, Gtk.IconSize.DIALOG)
            header.pack_start(icon, False, False, 0)

            title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            header.pack_start(title_box, True, True, 0)

            title = Gtk.Label(label="PEGPU Scaling", xalign=0)
            title.get_style_context().add_class("pegpu-title")
            title_box.pack_start(title, False, False, 0)

            display_label = Gtk.Label(label=f"DISPLAY={require_display(args.display)}", xalign=0)
            display_label.get_style_context().add_class("pegpu-muted")
            title_box.pack_start(display_label, False, False, 0)

            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            card.get_style_context().add_class("pegpu-scale-card")
            outer.pack_start(card, False, False, 0)

            scale_label = Gtk.Label(label="Scale", xalign=0)
            scale_label.get_style_context().add_class("pegpu-muted")
            card.pack_start(scale_label, False, False, 0)

            scale_grid = Gtk.Grid(column_spacing=6, row_spacing=6)
            card.pack_start(scale_grid, False, False, 0)

            for index, scale in enumerate(SUPPORTED_SCALES):
                button = Gtk.ToggleButton(label=f"{scale}x")
                button.get_style_context().add_class("pegpu-scale-button")
                button.connect("toggled", self.on_scale_toggled, scale)
                self.scale_buttons[scale] = button
                scale_grid.attach(button, index % 3, index // 3, 1, 1)

            footer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            footer.get_style_context().add_class("pegpu-footer")
            outer.pack_start(footer, False, False, 0)

            self.status = Gtk.Label(label=f"Ready on DISPLAY={require_display(args.display)}", xalign=0)
            self.status.set_ellipsize(Pango.EllipsizeMode.END)
            self.status.get_style_context().add_class("pegpu-muted")
            footer.pack_start(self.status, False, False, 0)

            button_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            button_row.set_halign(Gtk.Align.END)
            footer.pack_start(button_row, False, False, 0)

            self.apply_button = Gtk.Button(label="Apply")
            self.apply_button.get_style_context().add_class("suggested-action")
            self.apply_button.connect("clicked", self.on_apply)
            button_row.pack_start(self.apply_button, False, False, 0)

            self.reset_button = Gtk.Button(label="Reset")
            self.reset_button.connect("clicked", self.on_reset)
            button_row.pack_start(self.reset_button, False, False, 0)

            self.select_scale(self.selected_scale)

        def select_scale(self, scale: str) -> None:
            self.selected_scale = normalize_scale(scale)
            for value, button in self.scale_buttons.items():
                button.set_active(value == self.selected_scale)

        def on_scale_toggled(self, button: Any, scale: str) -> None:
            if self.busy:
                return
            if not button.get_active():
                return
            self.selected_scale = scale
            for value, other in self.scale_buttons.items():
                if value != scale and other.get_active():
                    other.set_active(False)
            self.status.set_text(f"Selected {scale}x")

        def set_busy(self, busy: bool) -> None:
            self.busy = busy
            for button in self.scale_buttons.values():
                button.set_sensitive(not busy)
            self.apply_button.set_sensitive(not busy)
            self.reset_button.set_sensitive(not busy)

        def apply_in_background(self, scale: str, done_text: str) -> None:
            if self.busy:
                return
            self.set_busy(True)
            self.status.set_text(f"Applying {scale}x...")

            def worker() -> None:
                error: str | None = None
                try:
                    apply_scale(scale, args.display, quiet=True)
                except Exception as exc:
                    error = str(exc)

                def finish() -> bool:
                    self.status.set_text(error or done_text)
                    self.set_busy(False)
                    return False

                GLib.idle_add(finish)

            threading.Thread(target=worker, daemon=True).start()

        def on_apply(self, _button: Any) -> None:
            if self.busy:
                return
            scale = self.selected_scale
            self.apply_in_background(scale, f"Applied {scale}x on DISPLAY={require_display(args.display)}")

        def on_reset(self, _button: Any) -> None:
            if self.busy:
                return
            self.select_scale("1")
            self.apply_in_background("1", f"Reset DISPLAY={require_display(args.display)}")

    window = ScalingWindow()
    window.show_all()
    Gtk.main()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pegpu-scaling", description="Sharp XFCE session scaling for PEGPU guests.")
    parser.add_argument("--display", help="Target X display/session, for example :10")
    parser.add_argument("--gui", action="store_true", help="Open the GTK scaling app")
    parser.add_argument("--quiet", action="store_true", help="Reduce command output")

    subparsers = parser.add_subparsers(dest="command")
    list_parser = subparsers.add_parser("list", help="List supported scale values")
    list_parser.add_argument("--json", action="store_true")

    get_parser = subparsers.add_parser("get", help="Show the saved scale for this session")
    get_parser.add_argument("--json", action="store_true")

    set_parser = subparsers.add_parser("set", help="Apply a scale")
    set_parser.add_argument("--scale", required=True)
    set_parser.add_argument("--quiet", action="store_true", help="Reduce command output")

    reset_parser = subparsers.add_parser("reset", help="Restore native/default sizing")
    reset_parser.add_argument("--quiet", action="store_true", help="Reduce command output")

    reapply_parser = subparsers.add_parser("reapply", help="Reapply saved scale for this session")
    reapply_parser.add_argument("--quiet", action="store_true", help="Reduce command output")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.gui or args.command is None:
            return run_gui(args)
        if args.command == "list":
            return command_list(args)
        if args.command == "get":
            return command_get(args)
        if args.command == "set":
            return command_set(args)
        if args.command == "reset":
            return command_reset(args)
        if args.command == "reapply":
            return command_reapply(args)
    except (RuntimeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
from dataclasses import dataclass
from typing import Any


APP_ICON_NAME = "pegpu-performance"
HELPER = os.environ.get("PEGPU_DMA_CONFIG", "/usr/sbin/apple-dma-config")
APPLY_NOTE = "Saved. To apply cleanly, stop the PEGPU server, shut down the VM, unplug the eGPU, plug it back in, then start PEGPU again."
EXPLANATION = "Controls the Apple DMA coalescing window. Larger windows can reduce DMA mapping overhead, while smaller windows favor stability."


@dataclass(frozen=True)
class PerformanceMode:
    key: str
    label: str
    shift: int
    kilobytes: int
    detail: str


MODES: tuple[PerformanceMode, ...] = (
    PerformanceMode("off", "Off", 0, 0, "Disable coalescing"),
    PerformanceMode("128kb", "128 KB - Stable", 17, 128, "Conservative default for reliability"),
    PerformanceMode("256kb", "256 KB - Gaming", 18, 256, "Balanced gaming performance"),
    PerformanceMode("512kb", "512 KB - Experimental", 19, 512, "Larger window for testing"),
)


def normalize_mode(value: str | None) -> PerformanceMode:
    raw = (value or "").strip().lower().replace("_", "").replace("-", "").replace(" ", "")
    aliases = {
        "none": "off",
        "disabled": "off",
        "disable": "off",
        "0": "off",
        "stable": "128kb",
        "128": "128kb",
        "128k": "128kb",
        "17": "128kb",
        "gaming": "256kb",
        "game": "256kb",
        "256": "256kb",
        "256k": "256kb",
        "18": "256kb",
        "experimental": "512kb",
        "experiment": "512kb",
        "512": "512kb",
        "512k": "512kb",
        "19": "512kb",
    }
    key = aliases.get(raw, raw)
    for mode in MODES:
        if mode.key == key:
            return mode
    raise ValueError(f"Unsupported PEGPU performance mode: {value}")


def mode_for_shift(shift: int | str | None) -> PerformanceMode | None:
    try:
        value = int(shift) if shift is not None else None
    except (TypeError, ValueError):
        return None
    for mode in MODES:
        if mode.shift == value:
            return mode
    return None


def helper_exists() -> bool:
    return os.path.exists(HELPER) and os.access(HELPER, os.X_OK)


def helper_base_args(privileged: bool = False) -> list[str]:
    if not helper_exists():
        raise RuntimeError("apple-dma-config is not installed yet. Refresh PEGPU guest tools, then try again.")
    if not privileged or os.geteuid() == 0:
        return [HELPER]
    pkexec = shutil.which("pkexec")
    if pkexec:
        return [pkexec, HELPER]
    sudo = shutil.which("sudo")
    if sudo:
        return [sudo, "-n", HELPER]
    raise RuntimeError("Saving this setting requires root access, but neither pkexec nor sudo is available.")


def run_helper(args: list[str], privileged: bool = False) -> str:
    command = helper_base_args(privileged) + args
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip()
        raise RuntimeError(message or f"apple-dma-config exited with status {result.returncode}")
    return result.stdout


def helper_json(args: list[str]) -> dict[str, Any]:
    text = run_helper(args)
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"apple-dma-config returned invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise RuntimeError("apple-dma-config returned unexpected JSON")
    return value


def command_list(args: argparse.Namespace) -> int:
    if args.json:
        print(json.dumps({"modes": [mode.__dict__ for mode in MODES]}, indent=2, sort_keys=True))
    else:
        for mode in MODES:
            print(f"{mode.key}\t{mode.label}")
    return 0


def command_get(args: argparse.Namespace) -> int:
    data = helper_json(["get", "--json"])
    if args.json:
        print(json.dumps(data, indent=2, sort_keys=True))
        return 0
    saved = display_mode(data.get("saved"))
    active = display_mode(data.get("active")) if data.get("active") else "Unknown"
    restart = "yes" if data.get("restartRequired") else "no"
    print(f"Saved mode:  {saved}")
    print(f"Active mode: {active}")
    print(f"Restart needed: {restart}")
    return 0


def command_set(args: argparse.Namespace) -> int:
    mode = normalize_mode(args.coalescing)
    output = run_helper(["set", "--coalescing", mode.key], privileged=True)
    if not args.quiet:
        print(output.strip())
    return 0


def command_reset(args: argparse.Namespace) -> int:
    output = run_helper(["reset"], privileged=True)
    if not args.quiet:
        print(output.strip())
    return 0


def display_mode(value: Any) -> str:
    if isinstance(value, dict):
        shift = value.get("shift")
        mode = mode_for_shift(shift)
        if mode:
            return mode.label
        label = value.get("label")
        if isinstance(label, str) and label:
            return label
    return "Unknown"


def current_saved_mode() -> PerformanceMode:
    try:
        data = helper_json(["get", "--json"])
        saved = data.get("saved")
        if isinstance(saved, dict):
            mode = mode_for_shift(saved.get("shift"))
            if mode:
                return mode
    except Exception:
        pass
    return normalize_mode("128kb")


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
              font-size: 16px;
            }
            .pegpu-muted {
              color: alpha(@theme_fg_color, 0.68);
            }
            .pegpu-card {
              border: 1px solid alpha(@theme_fg_color, 0.16);
              border-radius: 8px;
              background: alpha(@theme_base_color, 0.72);
              padding: 10px;
            }
            .pegpu-mode-button {
              min-width: 198px;
              min-height: 74px;
              padding: 8px;
            }
            .pegpu-mode-button:checked {
              background: #2f6fed;
              border-color: #2458bd;
              color: #ffffff;
            }
            .pegpu-mode-title {
              font-weight: 700;
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

    def mode_button(mode: PerformanceMode) -> Any:
        button = Gtk.ToggleButton()
        button.get_style_context().add_class("pegpu-mode-button")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        box.set_halign(Gtk.Align.START)
        title = Gtk.Label(label=mode.label, xalign=0)
        title.get_style_context().add_class("pegpu-mode-title")
        detail = Gtk.Label(label=mode.detail, xalign=0)
        detail.get_style_context().add_class("pegpu-muted")
        detail.set_line_wrap(True)
        box.pack_start(title, False, False, 0)
        box.pack_start(detail, False, False, 0)
        button.add(box)
        return button

    add_css()

    class PerformanceWindow(Gtk.Window):
        def __init__(self) -> None:
            super().__init__(title="PEGPU Performance")
            self.set_icon_name(APP_ICON_NAME)
            self.set_resizable(False)
            self.connect("destroy", Gtk.main_quit)
            self.get_style_context().add_class("pegpu-window")
            self.mode_buttons: dict[str, Any] = {}
            self.selected_mode = current_saved_mode()
            self.busy = False

            outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            outer.set_halign(Gtk.Align.START)
            set_margins(outer, 16)
            self.add(outer)

            header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            outer.pack_start(header, False, False, 0)

            icon = Gtk.Image.new_from_icon_name(APP_ICON_NAME, Gtk.IconSize.DIALOG)
            header.pack_start(icon, False, False, 0)

            title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
            title_box.set_halign(Gtk.Align.START)
            header.pack_start(title_box, False, False, 0)

            title = Gtk.Label(label="PEGPU Performance", xalign=0)
            title.get_style_context().add_class("pegpu-title")
            title_box.pack_start(title, False, False, 0)

            explanation = Gtk.Label(label=EXPLANATION, xalign=0)
            explanation.get_style_context().add_class("pegpu-muted")
            explanation.set_line_wrap(True)
            explanation.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
            explanation.set_max_width_chars(66)
            title_box.pack_start(explanation, False, False, 0)

            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            card.set_halign(Gtk.Align.START)
            card.get_style_context().add_class("pegpu-card")
            outer.pack_start(card, False, False, 0)

            grid = Gtk.Grid(column_spacing=8, row_spacing=8)
            grid.set_halign(Gtk.Align.START)
            card.pack_start(grid, False, False, 0)
            for index, mode in enumerate(MODES):
                button = mode_button(mode)
                button.connect("toggled", self.on_mode_toggled, mode)
                self.mode_buttons[mode.key] = button
                grid.attach(button, index % 2, index // 2, 1, 1)

            footer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            footer.get_style_context().add_class("pegpu-footer")
            outer.pack_start(footer, False, False, 0)

            self.status = Gtk.Label(label="", xalign=0)
            self.status.set_ellipsize(Pango.EllipsizeMode.END)
            self.status.set_max_width_chars(66)
            self.status.get_style_context().add_class("pegpu-muted")
            footer.pack_start(self.status, False, False, 0)

            self.note = Gtk.Label(label=APPLY_NOTE, xalign=0)
            self.note.set_line_wrap(True)
            self.note.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
            self.note.set_max_width_chars(66)
            self.note.get_style_context().add_class("pegpu-muted")
            footer.pack_start(self.note, False, False, 0)

            button_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            button_row.set_halign(Gtk.Align.END)
            footer.pack_start(button_row, False, False, 0)

            refresh_button = Gtk.Button(label="Refresh")
            refresh_button.connect("clicked", lambda _button: self.refresh_status())
            button_row.pack_start(refresh_button, False, False, 0)

            self.apply_button = Gtk.Button(label="Apply")
            self.apply_button.get_style_context().add_class("suggested-action")
            self.apply_button.connect("clicked", self.on_apply)
            button_row.pack_start(self.apply_button, False, False, 0)

            self.select_mode(self.selected_mode)
            self.refresh_status()

        def select_mode(self, mode: PerformanceMode) -> None:
            self.selected_mode = mode
            for key, button in self.mode_buttons.items():
                button.set_active(key == mode.key)

        def on_mode_toggled(self, button: Any, mode: PerformanceMode) -> None:
            if self.busy or not button.get_active():
                return
            self.selected_mode = mode
            for key, other in self.mode_buttons.items():
                if key != mode.key and other.get_active():
                    other.set_active(False)
            self.status.set_text(f"Selected {mode.label}")

        def set_busy(self, busy: bool) -> None:
            self.busy = busy
            for button in self.mode_buttons.values():
                button.set_sensitive(not busy)
            self.apply_button.set_sensitive(not busy)

        def refresh_status(self) -> None:
            try:
                data = helper_json(["get", "--json"])
                saved = display_mode(data.get("saved"))
                active = display_mode(data.get("active")) if data.get("active") else "Unknown"
                restart = "restart needed" if data.get("restartRequired") else "ready"
                self.status.set_text(f"Active: {active}   Saved: {saved}   Status: {restart}")
                saved_data = data.get("saved")
                if isinstance(saved_data, dict):
                    mode = mode_for_shift(saved_data.get("shift"))
                    if mode:
                        self.select_mode(mode)
            except Exception as exc:
                self.status.set_text(str(exc))

        def on_apply(self, _button: Any) -> None:
            if self.busy:
                return
            mode = self.selected_mode
            self.set_busy(True)
            self.status.set_text(f"Saving {mode.label}...")

            def worker() -> None:
                error: str | None = None
                try:
                    run_helper(["set", "--coalescing", mode.key], privileged=True)
                except Exception as exc:
                    error = str(exc)

                def finish() -> bool:
                    self.set_busy(False)
                    if error:
                        self.status.set_text(error)
                    else:
                        self.status.set_text(APPLY_NOTE)
                        self.refresh_status()
                    return False

                GLib.idle_add(finish)

            threading.Thread(target=worker, daemon=True).start()

    window = PerformanceWindow()
    window.show_all()
    Gtk.main()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pegpu-performance", description="PEGPU DMA coalescing performance control.")
    parser.add_argument("--gui", action="store_true", help="Open the GTK performance app")
    parser.add_argument("--quiet", action="store_true", help="Reduce command output")

    subparsers = parser.add_subparsers(dest="command")
    list_parser = subparsers.add_parser("list", help="List supported performance modes")
    list_parser.add_argument("--json", action="store_true")

    get_parser = subparsers.add_parser("get", help="Show current and saved performance mode")
    get_parser.add_argument("--json", action="store_true")

    set_parser = subparsers.add_parser("set", help="Save a performance mode")
    set_parser.add_argument("--coalescing", required=True)
    set_parser.add_argument("--quiet", action="store_true", help="Reduce command output")

    reset_parser = subparsers.add_parser("reset", help="Restore the stable default")
    reset_parser.add_argument("--quiet", action="store_true", help="Reduce command output")
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
    except (RuntimeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    parser.print_help()
    return 2

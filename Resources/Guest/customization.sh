#!/usr/bin/env bash
set -euo pipefail

MODE_DIR=/etc/pegpu
GUI_PREFS_FILE="$MODE_DIR/gui-prefs.conf"
GLOBAL_XFCE_CONFIG_DIR=/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
GLOBAL_PANEL_DEFAULT=/etc/xdg/xfce4/panel/default.xml
GUI_ASSET_DIR=/usr/share/pegpu/gui
WALLPAPER_DIR=/usr/share/backgrounds/pegpu
LOGO_FILE="$GUI_ASSET_DIR/PEGPU-logo-transparent.png"
DARK_WALLPAPER="$WALLPAPER_DIR/pegpu-dark.svg"
LIGHT_WALLPAPER="$WALLPAPER_DIR/pegpu-light.svg"
DARK_MENU_ICON="$GUI_ASSET_DIR/pegpu-menu-dark.svg"
LIGHT_MENU_ICON="$GUI_ASSET_DIR/pegpu-menu-light.svg"
HUMAN_USER="${PEGPU_DISPLAY_USER:-pegpu}"
XFCE_CHANGED=0

pegpu_customization_pref_value() {
  local key="$1" default="$2"
  if [ -f "$GUI_PREFS_FILE" ]; then
    awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); found=1; exit } END { exit found ? 0 : 1 }' "$GUI_PREFS_FILE" 2>/dev/null ||
      printf '%s\n' "$default"
  else
    printf '%s\n' "$default"
  fi
}

pegpu_customization_write_prefs() {
  local retina density appearance
  retina="${PEGPU_GUI_RETINA:-$(pegpu_customization_pref_value PEGPU_GUI_RETINA 1)}"
  density="${PEGPU_GUI_DENSITY:-$(pegpu_customization_pref_value PEGPU_GUI_DENSITY comfort)}"
  appearance="${PEGPU_GUI_APPEARANCE:-$(pegpu_customization_pref_value PEGPU_GUI_APPEARANCE dark)}"
  case "$retina" in
    0|1) ;;
    *) retina=1 ;;
  esac
  case "$appearance" in
    light|dark) ;;
    *) appearance=dark ;;
  esac
  install -d "$MODE_DIR"
  cat >"$GUI_PREFS_FILE" <<EOF
PEGPU_GUI_RETINA=$retina
PEGPU_GUI_DENSITY=$density
PEGPU_GUI_APPEARANCE=$appearance
EOF
  chmod 0644 "$GUI_PREFS_FILE"
}

pegpu_customization_appearance() {
  local appearance
  appearance="$(pegpu_customization_pref_value PEGPU_GUI_APPEARANCE dark)"
  case "$appearance" in
    light|dark) printf '%s\n' "$appearance" ;;
    *) printf '%s\n' dark ;;
  esac
}

pegpu_customization_theme_name() {
  if [ "$(pegpu_customization_appearance)" = "light" ]; then
    printf '%s\n' PEGPU-light
  else
    printf '%s\n' PEGPU-dark
  fi
}

pegpu_customization_wallpaper() {
  if [ "$(pegpu_customization_appearance)" = "light" ]; then
    printf '%s\n' "$LIGHT_WALLPAPER"
  else
    printf '%s\n' "$DARK_WALLPAPER"
  fi
}

pegpu_customization_menu_icon() {
  if [ "$(pegpu_customization_appearance)" = "light" ]; then
    printf '%s\n' "$LIGHT_MENU_ICON"
  else
    printf '%s\n' "$DARK_MENU_ICON"
  fi
}

pegpu_customization_user_home() {
  getent passwd "$HUMAN_USER" 2>/dev/null | cut -d: -f6 || true
}

pegpu_customization_write_user_file() {
  local path="$1" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if ! [ -f "$path" ] || ! cmp -s "$tmp" "$path"; then
    install -D -o "$HUMAN_USER" -g "$HUMAN_USER" -m 0644 "$tmp" "$path"
    XFCE_CHANGED=1
  fi
  rm -f "$tmp"
}

pegpu_customization_session_env() {
  local uid bus
  [ -n "${DISPLAY:-}" ] || return 1
  uid="$(id -u)"
  bus="/run/user/$uid/bus"
  export DISPLAY
  export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
  if [ -S "$bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$bus}"
  fi
}

pegpu_customization_display_matches() {
  local actual="$1" target="$2"
  [ -n "$actual" ] || return 1
  [ -n "$target" ] || return 0
  [ "${actual%.0}" = "${target%.0}" ]
}

pegpu_customization_main_session_pid() {
  local target_display pid display
  target_display="${1:-${DISPLAY:-}}"
  for pid in $(pgrep -u "$HUMAN_USER" xfce4-session 2>/dev/null || true) \
             $(pgrep -u "$HUMAN_USER" xfce4-panel 2>/dev/null || true) \
             $(pgrep -u "$HUMAN_USER" xfdesktop 2>/dev/null || true); do
    [ -n "$pid" ] || continue
    [ -r "/proc/$pid/environ" ] || continue
    display="$(tr '\0' '\n' <"/proc/$pid/environ" | awk -F= '$1 == "DISPLAY" { print substr($0, index($0, "=") + 1); exit }')"
    if pegpu_customization_display_matches "$display" "$target_display"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

pegpu_customization_run_session() {
  local uid bus pid display target_display xauthority dbus
  if [ "$(id -un 2>/dev/null || true)" = "$HUMAN_USER" ] && [ -n "${DISPLAY:-}" ]; then
    pegpu_customization_session_env
    "$@"
    return $?
  fi
  uid="$(id -u "$HUMAN_USER" 2>/dev/null || true)"
  [ -n "$uid" ] || return 1
  target_display="${DISPLAY:-}"
  pid="$(pegpu_customization_main_session_pid "$target_display" || true)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/environ" ]; then
    display="$(tr '\0' '\n' <"/proc/$pid/environ" | awk -F= '$1 == "DISPLAY" { print substr($0, index($0, "=") + 1); exit }')"
    xauthority="$(tr '\0' '\n' <"/proc/$pid/environ" | awk -F= '$1 == "XAUTHORITY" { print substr($0, index($0, "=") + 1); exit }')"
    dbus="$(tr '\0' '\n' <"/proc/$pid/environ" | awk -F= '$1 == "DBUS_SESSION_BUS_ADDRESS" { print substr($0, index($0, "=") + 1); exit }')"
    if [ -n "$display" ] && [ -n "$dbus" ]; then
      sudo -u "$HUMAN_USER" env DISPLAY="$display" XAUTHORITY="${xauthority:-/home/$HUMAN_USER/.Xauthority}" DBUS_SESSION_BUS_ADDRESS="$dbus" "$@"
      return $?
    fi
  fi
  [ -n "$target_display" ] || return 1
  bus="/run/user/$uid/bus"
  [ -S "$bus" ] || return 1
  sudo -u "$HUMAN_USER" env DISPLAY="$target_display" XAUTHORITY="/home/$HUMAN_USER/.Xauthority" DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" "$@"
}

pegpu_customization_xfconf_set() {
  pegpu_customization_run_session /usr/bin/timeout 4s xfconf-query -c "$1" -p "$2" -n -t "$3" -s "$4" >/dev/null 2>&1 || true
}

pegpu_customization_create_assets() {
  local logo_b64
  [ -f "$LOGO_FILE" ] || return 0
  install -d "$WALLPAPER_DIR" "$GUI_ASSET_DIR"
  logo_b64="$(base64 -w0 "$LOGO_FILE")"
  cat >"$DARK_WALLPAPER" <<EOS
<svg xmlns="http://www.w3.org/2000/svg" width="3840" height="2160" viewBox="0 0 3840 2160">
  <defs>
    <filter id="logo"><feColorMatrix type="matrix" values="0 0 0 0 0.94 0 0 0 0 0.91 0 0 0 0 0.84 0 0 0 0.18 0"/></filter>
  </defs>
  <rect width="3840" height="2160" fill="#2d2b27"/>
  <image href="data:image/png;base64,$logo_b64" x="1320" y="480" width="1200" height="1200" preserveAspectRatio="xMidYMid meet" filter="url(#logo)"/>
</svg>
EOS
  cat >"$LIGHT_WALLPAPER" <<EOS
<svg xmlns="http://www.w3.org/2000/svg" width="3840" height="2160" viewBox="0 0 3840 2160">
  <defs>
    <filter id="logo"><feColorMatrix type="matrix" values="0 0 0 0 0.07 0 0 0 0 0.065 0 0 0 0 0.055 0 0 0 0.30 0"/></filter>
  </defs>
  <rect width="3840" height="2160" fill="#b7b1a5"/>
  <image href="data:image/png;base64,$logo_b64" x="1320" y="480" width="1200" height="1200" preserveAspectRatio="xMidYMid meet" filter="url(#logo)"/>
</svg>
EOS
  cat >"$DARK_MENU_ICON" <<EOS
<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
  <defs>
    <filter id="logo"><feColorMatrix type="matrix" values="0 0 0 0 0.94 0 0 0 0 0.91 0 0 0 0 0.84 0 0 0 1 0"/></filter>
  </defs>
  <image href="data:image/png;base64,$logo_b64" x="6" y="6" width="84" height="84" preserveAspectRatio="xMidYMid meet" filter="url(#logo)"/>
</svg>
EOS
  cat >"$LIGHT_MENU_ICON" <<EOS
<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
  <defs>
    <filter id="logo"><feColorMatrix type="matrix" values="0 0 0 0 0.10 0 0 0 0 0.10 0 0 0 0 0.09 0 0 0 1 0"/></filter>
  </defs>
  <image href="data:image/png;base64,$logo_b64" x="6" y="6" width="84" height="84" preserveAspectRatio="xMidYMid meet" filter="url(#logo)"/>
</svg>
EOS
  chmod 0644 "$DARK_WALLPAPER" "$LIGHT_WALLPAPER" "$DARK_MENU_ICON" "$LIGHT_MENU_ICON"
}

pegpu_customization_theme_css() {
  local appearance="$1"
  if [ "$appearance" = "light" ]; then
    cat <<'CSS'

/* PEGPU global XFCE light skin */
.xfce4-panel.background,
.xfce4-panel.background.horizontal,
.xfce4-panel.background.vertical {
  background-color: #f7f7f4;
  background-image: none;
  color: #24221f;
  font-weight: normal;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background *,
.xfce4-panel.background label,
.xfce4-panel.background button label,
.xfce4-panel.background #applicationmenu-button label,
.xfce4-panel.background .tasklist button label {
  color: #24221f;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background button,
.xfce4-panel.background button.flat,
.xfce4-panel.background #applicationmenu-button,
.xfce4-panel.background .tasklist button,
.xfce4-panel.background .window-button {
  background-color: #f7f7f4;
  background-image: none;
  border-color: transparent;
  box-shadow: none;
  color: #24221f;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background button:hover,
.xfce4-panel.background #applicationmenu-button:hover,
.xfce4-panel.background .tasklist button:hover,
.xfce4-panel.background .window-button:hover {
  background-color: #ebe9e2;
  background-image: none;
  border-color: #d8d5cc;
  color: #24221f;
  box-shadow: none;
}

.xfce4-panel.background button:checked,
.xfce4-panel.background button:active,
.xfce4-panel.background #applicationmenu-button:checked,
.xfce4-panel.background #applicationmenu-button:active,
.xfce4-panel.background .tasklist button:checked,
.xfce4-panel.background .tasklist button:active,
.xfce4-panel.background .window-button:checked,
.xfce4-panel.background .window-button:active {
  background-color: #dedbd1;
  background-image: none;
  border-color: #c9c2b5;
  color: #24221f;
  box-shadow: none;
}

.xfce4-panel.background .tasklist button.flat {
  background-color: #ebe9e2;
  background-image: none;
  border-color: #d8d5cc;
  color: #24221f;
  box-shadow: none;
}

.xfce4-panel.background .tasklist button:checked label,
.xfce4-panel.background .tasklist button:active label,
.xfce4-panel.background .window-button:checked label,
.xfce4-panel.background .window-button:active label {
  color: #1f1d1a;
}

.xfce4-panel.background menu,
.xfce4-panel.background menuitem {
  background-color: #f7f7f4;
  background-image: none;
  color: #24221f;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background menu label,
.xfce4-panel.background menuitem label {
  color: #24221f;
  text-shadow: none;
}

.xfce4-panel.background menuitem:hover,
.xfce4-panel.background menuitem:selected {
  background-color: #dedbd1;
  background-image: none;
  color: #1f1d1a;
}

CSS
  else
    cat <<'CSS'

/* PEGPU global XFCE dark skin */
.xfce4-panel.background,
.xfce4-panel.background.horizontal,
.xfce4-panel.background.vertical {
  background-color: #2d2b27;
  background-image: none;
  color: #f0e9d8;
  font-weight: normal;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background *,
.xfce4-panel.background label,
.xfce4-panel.background button label,
.xfce4-panel.background #applicationmenu-button label,
.xfce4-panel.background .tasklist button label {
  color: #f0e9d8;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background button,
.xfce4-panel.background button.flat,
.xfce4-panel.background #applicationmenu-button,
.xfce4-panel.background .tasklist button,
.xfce4-panel.background .window-button {
  background-color: #2d2b27;
  background-image: none;
  border-color: transparent;
  box-shadow: none;
  color: #f0e9d8;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background button:hover,
.xfce4-panel.background #applicationmenu-button:hover,
.xfce4-panel.background .tasklist button:hover,
.xfce4-panel.background .window-button:hover {
  background-color: #3a362f;
  background-image: none;
  border-color: #565044;
  color: #f0e9d8;
  box-shadow: none;
}

.xfce4-panel.background button:checked,
.xfce4-panel.background button:active,
.xfce4-panel.background #applicationmenu-button:checked,
.xfce4-panel.background #applicationmenu-button:active,
.xfce4-panel.background .tasklist button:checked,
.xfce4-panel.background .tasklist button:active,
.xfce4-panel.background .window-button:checked,
.xfce4-panel.background .window-button:active {
  background-color: #484238;
  background-image: none;
  border-color: #6b604e;
  color: #f0e9d8;
  box-shadow: none;
}

.xfce4-panel.background .tasklist button.flat {
  background-color: #3a362f;
  background-image: none;
  border-color: #565044;
  color: #f0e9d8;
  box-shadow: none;
}

.xfce4-panel.background .tasklist button:checked label,
.xfce4-panel.background .tasklist button:active label,
.xfce4-panel.background .window-button:checked label,
.xfce4-panel.background .window-button:active label {
  color: #fff5dd;
}

.xfce4-panel.background menu,
.xfce4-panel.background menuitem {
  background-color: #302d28;
  background-image: none;
  color: #f0e9d8;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background menu label,
.xfce4-panel.background menuitem label {
  color: #f0e9d8;
  text-shadow: none;
}

.xfce4-panel.background menuitem:hover,
.xfce4-panel.background menuitem:selected {
  background-color: #484238;
  background-image: none;
  color: #fff5dd;
}

CSS
  fi
}

pegpu_customization_strip_desktop_icon_shadow_theme() {
  local root="$1" file
  for file in "$root"/gtk-3.0/gtk.css "$root"/gtk-3.0/gtk-dark.css; do
    [ -f "$file" ] || continue
    perl -pi -e '
      if (/XfdesktopIconView/) {
        s/[[:space:]]*text-shadow:[^;{}]+;//g;
        s/[[:space:]]*-gtk-icon-shadow:[^;{}]+;//g;
      }
    ' "$file"
  done
  file="$root/gtk-2.0/gtkrc"
  [ -f "$file" ] || return 0
  perl -pi -e '
    s/(XfdesktopIconView::(?:selected-)?shadow-[xy]-offset[[:space:]]*=[[:space:]]*)-?[0-9]+/${1}0/g;
    s/(XfdesktopIconView::shadow-blur-radius[[:space:]]*=[[:space:]]*)-?[0-9]+/${1}0/g;
  ' "$file"
}

pegpu_customization_install_theme_variant() {
  local name="$1" base="$2" appearance="$3" tmp dest css
  dest="/usr/share/themes/$name"
  tmp="$(mktemp -d)"
  rm -rf "$tmp"
  if [ -d "/usr/share/themes/$base" ]; then
    cp -a "/usr/share/themes/$base" "$tmp"
  else
    install -d "$tmp/gtk-3.0"
    cat >"$tmp/index.theme" <<EOF
[Desktop Entry]
Type=X-GNOME-Metatheme
Name=$name
GtkTheme=$name
EOF
  fi
  install -d "$tmp/gtk-3.0"
  css="$tmp/gtk-3.0/gtk.css"
  [ -f "$css" ] || : >"$css"
  pegpu_customization_strip_desktop_icon_shadow_theme "$tmp"
  pegpu_customization_theme_css "$appearance" >>"$css"
  rm -rf "$dest"
  mv "$tmp" "$dest"
  chmod -R a+rX "$dest"
}

pegpu_customization_install_global_skin() {
  pegpu_customization_create_assets
  pegpu_customization_install_theme_variant PEGPU-light Greybird light
  pegpu_customization_install_theme_variant PEGPU-dark Greybird-dark dark
  pegpu_customization_install_backdrop_fallbacks
}

pegpu_customization_xsettings_xml() {
  local theme
  theme="$(pegpu_customization_theme_name)"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="$theme"/>
    <property name="IconThemeName" type="string" value="Adwaita"/>
  </property>
</channel>
EOF
}

pegpu_customization_seed_xsettings() {
  local config_dir home
  home="$(pegpu_customization_user_home)"
  [ -n "$home" ] || return 0
  config_dir="$home/.config/xfce4/xfconf/xfce-perchannel-xml"
  install -d "$GLOBAL_XFCE_CONFIG_DIR"
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" "$config_dir"
  pegpu_customization_xsettings_xml >"$GLOBAL_XFCE_CONFIG_DIR/xsettings.xml"
  chmod 0644 "$GLOBAL_XFCE_CONFIG_DIR/xsettings.xml"
  pegpu_customization_write_user_file "$config_dir/xsettings.xml" <"$GLOBAL_XFCE_CONFIG_DIR/xsettings.xml"
}

pegpu_customization_desktop_icon_label_rgba() {
  if [ "$(pegpu_customization_appearance)" = "light" ]; then
    printf '%s\n' "0.1215686275 0.1137254902 0.1019607843 1.0"
  else
    printf '%s\n' "0.9411764706 0.9137254902 0.8470588235 1.0"
  fi
}

pegpu_customization_desktop_icon_label_xml() {
  local red green blue alpha
  read -r red green blue alpha <<EOF
$(pegpu_customization_desktop_icon_label_rgba)
EOF
  cat <<EOF
  <property name="desktop-icons" type="empty">
    <property name="use-custom-label-text-color" type="bool" value="true"/>
    <property name="label-text-color" type="array">
      <value type="double" value="$red"/>
      <value type="double" value="$green"/>
      <value type="double" value="$blue"/>
      <value type="double" value="$alpha"/>
    </property>
    <property name="use-custom-label-background-color" type="bool" value="false"/>
  </property>
EOF
}

pegpu_customization_apply_desktop_icon_label_color_now() {
  local red green blue alpha
  read -r red green blue alpha <<EOF
$(pegpu_customization_desktop_icon_label_rgba)
EOF
  pegpu_customization_xfconf_set xfce4-desktop /desktop-icons/use-custom-label-text-color bool true
  pegpu_customization_run_session /usr/bin/timeout 4s xfconf-query -c xfce4-desktop -p /desktop-icons/label-text-color -n -a \
    -t double -s "$red" \
    -t double -s "$green" \
    -t double -s "$blue" \
    -t double -s "$alpha" >/dev/null 2>&1 || true
  pegpu_customization_xfconf_set xfce4-desktop /desktop-icons/use-custom-label-background-color bool false
}

pegpu_customization_wallpaper_monitor_xml() {
  local name="$1" wallpaper="$2"
  cat <<EOF
      <property name="$name" type="empty">
        <property name="color-style" type="int" value="0"/>
        <property name="image-show" type="bool" value="true"/>
        <property name="image-path" type="string" value="$wallpaper"/>
        <property name="last-image" type="string" value="$wallpaper"/>
        <property name="last-single-image" type="string" value="$wallpaper"/>
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="$wallpaper"/>
        </property>
      </property>
EOF
}

pegpu_customization_static_wallpaper_monitors() {
  cat <<'EOF'
monitor0
monitor1
monitordefault
monitorVirtual-1
monitorVirtual-0
monitorVirtual1
monitorHDMI-0
monitorHDMI-1
monitorHDMI-2
monitorHDMI-A-1
monitorHDMI-A-2
monitorDP-0
monitorDP-1
monitorDP-2
monitorDP-3
monitorDisplayPort-0
monitorDVI-D-0
monitorDVI-D-1
monitorDVI-I-0
monitorDVI-I-1
monitorVGA-0
monitorVGA-1
monitoreDP-1
monitoreDP-2
EOF
}

pegpu_customization_configured_wallpaper_monitors() {
  local home config file
  home="$(pegpu_customization_user_home)"
  [ -n "$home" ] || return 0
  for file in \
    "$home/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" \
    "$GLOBAL_XFCE_CONFIG_DIR/xfce4-desktop.xml"; do
    [ -f "$file" ] || continue
    grep -Eo 'name="monitor[^"]+"' "$file" | sed 's/^name="//; s/"$//'
  done
}

pegpu_customization_connected_wallpaper_monitors() {
  pegpu_customization_run_session /usr/bin/timeout 4s xrandr --query 2>/dev/null |
    awk '$2 == "connected" { print "monitor" $1 }' || true
}

pegpu_customization_wallpaper_monitors() {
  {
    pegpu_customization_static_wallpaper_monitors
    pegpu_customization_configured_wallpaper_monitors
    pegpu_customization_connected_wallpaper_monitors
  } | awk 'NF && !seen[$0]++'
}

pegpu_customization_install_backdrop_fallbacks() {
  local wallpaper target
  [ "$(id -u)" -eq 0 ] || return 0
  wallpaper="$(pegpu_customization_wallpaper)"
  [ -f "$wallpaper" ] || return 0
  install -d "$WALLPAPER_DIR" /usr/share/backgrounds/xfce /usr/share/xfce4/backdrops
  cp -f "$wallpaper" "$WALLPAPER_DIR/current.svg"
  for target in \
    /usr/share/backgrounds/greybird.svg \
    /usr/share/xfce4/backdrops/greybird-wall.svg \
    /usr/share/backgrounds/xfce/xfce-x.svg \
    /usr/share/backgrounds/xfce/xfce-light.svg \
    /usr/share/backgrounds/xfce/xfce-cp-dark.svg \
    /usr/share/backgrounds/xfce/xfce-flower.svg \
    /usr/share/backgrounds/xfce/xfce-leaves.svg \
    /usr/share/backgrounds/xfce/xfce-mouserace.svg \
    /usr/share/backgrounds/xfce/xfce-shapes.svg \
    /usr/share/backgrounds/xfce/xfce-stripes.svg \
    /usr/share/backgrounds/xfce/xfce-teal.svg \
    /usr/share/backgrounds/xfce/xfce-verticals.svg; do
    [ -d "$(dirname "$target")" ] || continue
    cp -f "$wallpaper" "$target"
    chmod 0644 "$target"
  done
  chmod 0644 "$WALLPAPER_DIR/current.svg"
}

pegpu_customization_seed_wallpaper() {
  local wallpaper config_dir home monitor
  home="$(pegpu_customization_user_home)"
  [ -n "$home" ] || return 0
  wallpaper="$(pegpu_customization_wallpaper)"
  [ -f "$wallpaper" ] || return 0
  config_dir="$home/.config/xfce4/xfconf/xfce-perchannel-xml"
  install -d "$GLOBAL_XFCE_CONFIG_DIR"
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" "$config_dir"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<channel name="xfce4-desktop" version="1.0">'
    pegpu_customization_desktop_icon_label_xml
    printf '%s\n' '  <property name="backdrop" type="empty">'
    printf '%s\n' '    <property name="screen0" type="empty">'
    while IFS= read -r monitor; do
      [ -n "$monitor" ] || continue
      pegpu_customization_wallpaper_monitor_xml "$monitor" "$wallpaper"
    done < <(pegpu_customization_wallpaper_monitors)
    printf '%s\n' '    </property>'
    printf '%s\n' '  </property>'
    printf '%s\n' '</channel>'
  } >"$GLOBAL_XFCE_CONFIG_DIR/xfce4-desktop.xml"
  chmod 0644 "$GLOBAL_XFCE_CONFIG_DIR/xfce4-desktop.xml"
  pegpu_customization_write_user_file "$config_dir/xfce4-desktop.xml" <"$GLOBAL_XFCE_CONFIG_DIR/xfce4-desktop.xml"
}

pegpu_customization_apply_wallpaper_now() {
  local wallpaper monitor base
  wallpaper="$(pegpu_customization_wallpaper)"
  [ -f "$wallpaper" ] || return 0
  while IFS= read -r monitor; do
    [ -n "$monitor" ] || continue
    base="/backdrop/screen0/$monitor"
    pegpu_customization_xfconf_set xfce4-desktop "$base/color-style" int 0
    pegpu_customization_xfconf_set xfce4-desktop "$base/image-show" bool true
    pegpu_customization_xfconf_set xfce4-desktop "$base/image-path" string "$wallpaper"
    pegpu_customization_xfconf_set xfce4-desktop "$base/last-image" string "$wallpaper"
    pegpu_customization_xfconf_set xfce4-desktop "$base/last-single-image" string "$wallpaper"
    pegpu_customization_xfconf_set xfce4-desktop "$base/workspace0/color-style" int 0
    pegpu_customization_xfconf_set xfce4-desktop "$base/workspace0/image-style" int 5
    pegpu_customization_xfconf_set xfce4-desktop "$base/workspace0/last-image" string "$wallpaper"
  done < <(pegpu_customization_wallpaper_monitors)
  pegpu_customization_run_session /usr/bin/timeout 4s xfdesktop --reload >/dev/null 2>&1 || true
}

pegpu_customization_panel_xml() {
  local menu_icon
  menu_icon="$(pegpu_customization_menu_icon)"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=10;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="applicationsmenu">
      <property name="button-icon" type="string" value="$menu_icon"/>
      <property name="show-button-title" type="bool" value="true"/>
      <property name="button-title" type="string" value="Applications"/>
    </property>
    <property name="plugin-2" type="string" value="tasklist"/>
  </property>
</channel>
EOF
}

pegpu_customization_seed_panel() {
  local config_dir home panel_file
  home="$(pegpu_customization_user_home)"
  [ -n "$home" ] || return 0
  config_dir="$home/.config/xfce4/xfconf/xfce-perchannel-xml"
  panel_file="$config_dir/xfce4-panel.xml"
  install -d /etc/xdg/xfce4/panel
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" "$config_dir"
  pegpu_customization_panel_xml >"$GLOBAL_PANEL_DEFAULT"
  chmod 0644 "$GLOBAL_PANEL_DEFAULT"
  pegpu_customization_write_user_file "$panel_file" <"$GLOBAL_PANEL_DEFAULT"
}

pegpu_customization_disable_idle_locking() {
  /usr/bin/timeout 15s systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
  /usr/bin/timeout 15s systemctl disable --now light-locker xfce4-screensaver xscreensaver >/dev/null 2>&1 || true
  install -d /etc/systemd/logind.conf.d
  cat >/etc/systemd/logind.conf.d/90-pegpu-no-sleep.conf <<'EOS'
[Login]
IdleAction=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOS
  /usr/bin/timeout 15s systemctl restart systemd-logind >/dev/null 2>&1 || true
  pegpu_customization_xfconf_set xfce4-session /general/LockCommand string ""
  pegpu_customization_xfconf_set xfce4-power-manager /xfce4-power-manager/presentation-mode bool true
  pegpu_customization_xfconf_set xfce4-power-manager /xfce4-power-manager/blank-on-ac int 0
  pegpu_customization_xfconf_set xfce4-power-manager /xfce4-power-manager/blank-on-battery int 0
  pegpu_customization_xfconf_set xfce4-power-manager /xfce4-power-manager/dpms-enabled bool false
  pegpu_customization_xfconf_set xfce4-power-manager /xfce4-power-manager/lock-screen-suspend-hibernate bool false
  pegpu_customization_run_session /usr/bin/timeout 4s xset s off -dpms s noblank >/dev/null 2>&1 || true
}

pegpu_customization_install_no_idle_autostart() {
  install -d /usr/local/libexec/pegpu
  cat >/usr/local/libexec/pegpu/no-idle-session.sh <<'EOS'
#!/bin/sh
set +e

while :; do
  xset s off -dpms s noblank >/dev/null 2>&1 || true
  xset dpms force on >/dev/null 2>&1 || true
  xfce4-screensaver-command --deactivate >/dev/null 2>&1 || true
  xfconf-query -c xfce4-session -p /general/LockCommand -n -t string -s "" >/dev/null 2>&1 || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/presentation-mode -n -t bool -s true >/dev/null 2>&1 || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -n -t int -s 0 >/dev/null 2>&1 || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-battery -n -t int -s 0 >/dev/null 2>&1 || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false >/dev/null 2>&1 || true
  sleep 60
done
EOS
  chmod 0755 /usr/local/libexec/pegpu/no-idle-session.sh
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" "/home/$HUMAN_USER/.config/autostart"
  cat >"/home/$HUMAN_USER/.config/autostart/pegpu-no-idle.desktop" <<'EOS'
[Desktop Entry]
Type=Application
Name=PEGPU No Idle Lock
Exec=/usr/local/libexec/pegpu/no-idle-session.sh
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOS
  chown "$HUMAN_USER:$HUMAN_USER" "/home/$HUMAN_USER/.config/autostart/pegpu-no-idle.desktop"
}

pegpu_customization_install_appearance_autostart() {
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" "/home/$HUMAN_USER/.config/autostart"
  cat >"/home/$HUMAN_USER/.config/autostart/pegpu-appearance.desktop" <<'EOS'
[Desktop Entry]
Type=Application
Name=PEGPU Appearance
Exec=/bin/sh -lc 'sleep 1; /usr/local/libexec/pegpu/customization.sh apply-session-appearance'
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOS
  chown "$HUMAN_USER:$HUMAN_USER" "/home/$HUMAN_USER/.config/autostart/pegpu-appearance.desktop"
}

pegpu_customization_apply_global_settings_now() {
  local theme menu_icon
  theme="$(pegpu_customization_theme_name)"
  menu_icon="$(pegpu_customization_menu_icon)"
  pegpu_customization_xfconf_set xsettings /Net/ThemeName string "$theme"
  pegpu_customization_xfconf_set xsettings /Net/IconThemeName string Adwaita
  pegpu_customization_xfconf_set xfce4-panel /plugins/plugin-1/button-icon string "$menu_icon"
  pegpu_customization_xfconf_set xfce4-panel /plugins/plugin-1/show-button-title bool true
  pegpu_customization_xfconf_set xfce4-panel /plugins/plugin-1/button-title string Applications
  pegpu_customization_apply_desktop_icon_label_color_now
  pegpu_customization_apply_wallpaper_now
}

pegpu_customization_select_best_xrandr_mode() {
  [ -n "${DISPLAY:-}" ] || return 1
  DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" xrandr --query 2>/dev/null | awk '
    function abs(value) { return value < 0 ? -value : value }
    /^[^[:space:]]/ {
      connected = ($2 == "connected")
      output = connected ? $1 : ""
      output_aspect = 0
      if (connected) {
        for (i = 1; i <= NF - 2; i++) {
          if ($i ~ /^[0-9]+mm$/ && $(i + 1) == "x" && $(i + 2) ~ /^[0-9]+mm$/) {
            phys_w = $i
            phys_h = $(i + 2)
            gsub(/mm$/, "", phys_w)
            gsub(/mm$/, "", phys_h)
            if (phys_w + 0 > 0 && phys_h + 0 > 0) {
              output_aspect = (phys_w + 0) / (phys_h + 0)
            }
          }
        }
      }
      next
    }
    connected && /^[[:space:]]+[0-9]+x[0-9]+[[:space:]]/ {
      mode = $1
      split(mode, dims, "x")
      width = dims[1] + 0
      height = dims[2] + 0
      area = width * height
      refresh = 0
      preferred = 0
      current = 0
      for (i = 2; i <= NF; i++) {
        value = $i
        if (value ~ /[*]/) current = 1
        if (value ~ /[+]/) preferred = 1
        gsub(/[*+]/, "", value)
        if (value + 0 > refresh) refresh = value + 0
      }
      mode_aspect = height > 0 ? width / height : 0
      aspect_penalty = 0
      if (output_aspect > 0 && mode_aspect > 0) {
        aspect_penalty = abs(output_aspect - mode_aspect) * 10000000
      }
      score = area - aspect_penalty + preferred * 100000 + current * 10 + refresh
      if (score > best_score) {
        best_score = score
        best_output = output
        best_mode = mode
      }
    }
    END {
      if (best_output != "" && best_mode != "") {
        print best_output " " best_mode
      }
    }'
}

pegpu_customization_apply_best_xrandr_mode() {
  local best output target_mode current
  [ -n "${DISPLAY:-}" ] || return 0
  best="$(pegpu_customization_select_best_xrandr_mode || true)"
  [ -n "$best" ] || return 0
  read -r output target_mode <<EOF
$best
EOF
  [ -n "$output" ] && [ -n "$target_mode" ] || return 0
  current="$(DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" xrandr --query 2>/dev/null | awk -v output="$output" '
    $1 == output && $2 == "connected" {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) {
          split($i, parts, "+")
          print parts[1]
          exit
        }
      }
    }')"
  [ "$current" = "$target_mode" ] ||
    DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" xrandr --output "$output" --mode "$target_mode" --primary >/dev/null 2>&1 ||
    true
}

pegpu_customization_reapply_scaling() {
  local pid display xauthority dbus
  command -v pegpu-scaling >/dev/null 2>&1 || return 0
  if [ "$(id -un 2>/dev/null || true)" = "$HUMAN_USER" ]; then
    [ -n "${DISPLAY:-}" ] || return 0
    pegpu-scaling --display "$DISPLAY" reapply --quiet >/dev/null 2>&1 || true
  else
    if [ -n "${DISPLAY:-}" ]; then
      pegpu_customization_run_session pegpu-scaling --display "$DISPLAY" reapply --quiet >/dev/null 2>&1 || true
      return 0
    fi
    for pid in $(pgrep -u "$HUMAN_USER" xfce4-session 2>/dev/null || true); do
      [ -r "/proc/$pid/environ" ] || continue
      display="$(tr '\0' '\n' <"/proc/$pid/environ" | awk -F= '$1 == "DISPLAY" { print substr($0, index($0, "=") + 1); exit }')"
      [ -n "$display" ] || continue
      xauthority="$(tr '\0' '\n' <"/proc/$pid/environ" | awk -F= '$1 == "XAUTHORITY" { print substr($0, index($0, "=") + 1); exit }')"
      dbus="$(tr '\0' '\n' <"/proc/$pid/environ" | awk -F= '$1 == "DBUS_SESSION_BUS_ADDRESS" { print substr($0, index($0, "=") + 1); exit }')"
      sudo -u "$HUMAN_USER" env DISPLAY="$display" XAUTHORITY="${xauthority:-/home/$HUMAN_USER/.Xauthority}" DBUS_SESSION_BUS_ADDRESS="$dbus" \
        pegpu-scaling --display "$display" reapply --quiet >/dev/null 2>&1 || true
    done
  fi
}

pegpu_customization_apply_primary_display() {
  pegpu_customization_session_env
  xdpyinfo >/dev/null 2>&1 || return 0
  pegpu_customization_apply_best_xrandr_mode
  pegpu_customization_reapply_scaling
}

pegpu_customization_install_global_defaults() {
  pegpu_customization_install_global_skin
  pegpu_customization_seed_xsettings
  pegpu_customization_seed_wallpaper
  pegpu_customization_seed_panel
  pegpu_customization_install_appearance_autostart
}

pegpu_customization_apply_boot_defaults() {
  pegpu_customization_install_no_idle_autostart
  pegpu_customization_disable_idle_locking
  pegpu_customization_install_global_defaults
  pegpu_customization_reapply_scaling
  pegpu_customization_apply_global_settings_now
}

pegpu_customization_disable_idle() {
  pegpu_customization_install_no_idle_autostart
  pegpu_customization_disable_idle_locking
}

pegpu_customization_usage() {
  printf 'usage: %s {write-prefs|create-assets|install-global-defaults|apply-boot-defaults|disable-idle|apply-session-appearance|apply-primary-display}\n' "$0" >&2
}

pegpu_customization_main() {
  case "${1:-}" in
    write-prefs)
      pegpu_customization_write_prefs
      ;;
    create-assets)
      pegpu_customization_create_assets
      ;;
    install-global-defaults)
      pegpu_customization_install_global_defaults
      ;;
    apply-boot-defaults)
      pegpu_customization_apply_boot_defaults
      ;;
    disable-idle)
      pegpu_customization_disable_idle
      ;;
    apply-session-appearance)
      pegpu_customization_install_backdrop_fallbacks
      pegpu_customization_apply_global_settings_now
      ;;
    apply-primary-display)
      pegpu_customization_apply_primary_display
      ;;
    *)
      pegpu_customization_usage
      exit 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  pegpu_customization_main "$@"
fi

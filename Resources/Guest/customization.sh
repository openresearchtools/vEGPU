#!/usr/bin/env bash
set -euo pipefail

MODE_DIR=/etc/vegpu
GUI_PREFS_FILE="$MODE_DIR/gui-prefs.conf"
STATE_DIR=/var/lib/vegpu/gui
GLOBAL_XFCONF_DIR=/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
GLOBAL_PANEL_DEFAULT=/etc/xdg/xfce4/panel/default.xml
GUI_ASSET_DIR=/usr/share/vegpu/gui
WALLPAPER_DIR=/usr/share/backgrounds/vegpu
LOGO_FILE="$GUI_ASSET_DIR/vEGPU-logo-transparent.png"
LIGHT_WALLPAPER="$WALLPAPER_DIR/vegpu-light.svg"
DARK_WALLPAPER="$WALLPAPER_DIR/vegpu-dark.svg"
LIGHT_MENU_ICON="$GUI_ASSET_DIR/vegpu-menu-light.svg"
DARK_MENU_ICON="$GUI_ASSET_DIR/vegpu-menu-dark.svg"
HUMAN_USER="${VEGPU_DISPLAY_USER:-vegpu}"
SESSION_CHANGED=0

pref_value() {
  local key="$1" default="$2"
  if [ -f "$GUI_PREFS_FILE" ]; then
    awk -F= -v key="$key" '
      $1 == key { print substr($0, index($0, "=") + 1); found = 1; exit }
      END { exit found ? 0 : 1 }
    ' "$GUI_PREFS_FILE" 2>/dev/null || printf '%s\n' "$default"
  else
    printf '%s\n' "$default"
  fi
}

write_prefs() {
  local retina density appearance
  retina="${VEGPU_GUI_RETINA:-$(pref_value VEGPU_GUI_RETINA 1)}"
  density="${VEGPU_GUI_DENSITY:-$(pref_value VEGPU_GUI_DENSITY comfort)}"
  appearance="${VEGPU_GUI_APPEARANCE:-$(pref_value VEGPU_GUI_APPEARANCE dark)}"
  case "$retina" in 0|1) ;; *) retina=1 ;; esac
  case "$appearance" in light|dark) ;; *) appearance=dark ;; esac
  install -d "$MODE_DIR"
  cat >"$GUI_PREFS_FILE" <<EOF
VEGPU_GUI_RETINA=$retina
VEGPU_GUI_DENSITY=$density
VEGPU_GUI_APPEARANCE=$appearance
EOF
  chmod 0644 "$GUI_PREFS_FILE"
}

appearance() {
  case "$(pref_value VEGPU_GUI_APPEARANCE dark)" in
    light) printf '%s\n' light ;;
    *) printf '%s\n' dark ;;
  esac
}

theme_name() {
  if [ "$(appearance)" = light ]; then
    printf '%s\n' vEGPU-light
  else
    printf '%s\n' vEGPU-dark
  fi
}

wallpaper_path() {
  if [ "$(appearance)" = light ]; then
    printf '%s\n' "$LIGHT_WALLPAPER"
  else
    printf '%s\n' "$DARK_WALLPAPER"
  fi
}

menu_icon_path() {
  if [ "$(appearance)" = light ]; then
    printf '%s\n' "$LIGHT_MENU_ICON"
  else
    printf '%s\n' "$DARK_MENU_ICON"
  fi
}

desktop_text_color() {
  if [ "$(appearance)" = light ]; then
    printf '%s\n' '#1f1d1a'
  else
    printf '%s\n' '#f0e9d8'
  fi
}

human_home() {
  getent passwd "$HUMAN_USER" 2>/dev/null | cut -d: -f6 || true
}

write_root_file() {
  local path="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if ! [ -f "$path" ] || ! cmp -s "$tmp" "$path"; then
    install -D -m "$mode" "$tmp" "$path"
  fi
  rm -f "$tmp"
}

write_user_file() {
  local path="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if ! [ -f "$path" ] || ! cmp -s "$tmp" "$path"; then
    install -D -o "$HUMAN_USER" -g "$HUMAN_USER" -m "$mode" "$tmp" "$path"
  fi
  rm -f "$tmp"
}

display_matches() {
  local actual="$1" wanted="$2"
  [ -n "$actual" ] || return 1
  [ -n "$wanted" ] || return 0
  [ "${actual%.0}" = "${wanted%.0}" ]
}

session_pid() {
  local wanted="${DISPLAY:-}" pid display
  for pid in $(pgrep -u "$HUMAN_USER" xfce4-session 2>/dev/null || true) \
             $(pgrep -u "$HUMAN_USER" xfsettingsd 2>/dev/null || true) \
             $(pgrep -u "$HUMAN_USER" xfdesktop 2>/dev/null || true); do
    [ -r "/proc/$pid/environ" ] || continue
    display="$(tr '\0' '\n' <"/proc/$pid/environ" | awk -F= '$1 == "DISPLAY" { print substr($0, index($0, "=") + 1); exit }')"
    if display_matches "$display" "$wanted"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

session_run() {
  local pid uid display xauthority dbus bus
  if [ "$(id -un 2>/dev/null || true)" = "$HUMAN_USER" ] && [ -n "${DISPLAY:-}" ]; then
    export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
    bus="/run/user/$(id -u)/bus"
    [ -S "$bus" ] && export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$bus}"
    "$@"
    return $?
  fi

  pid="$(session_pid || true)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/environ" ]; then
    display="$(tr '\0' '\n' <"/proc/$pid/environ" | awk -F= '$1 == "DISPLAY" { print substr($0, index($0, "=") + 1); exit }')"
    xauthority="$(tr '\0' '\n' <"/proc/$pid/environ" | awk -F= '$1 == "XAUTHORITY" { print substr($0, index($0, "=") + 1); exit }')"
    dbus="$(tr '\0' '\n' <"/proc/$pid/environ" | awk -F= '$1 == "DBUS_SESSION_BUS_ADDRESS" { print substr($0, index($0, "=") + 1); exit }')"
    [ -n "$display" ] || return 1
    sudo -u "$HUMAN_USER" env \
      DISPLAY="$display" \
      XAUTHORITY="${xauthority:-/home/$HUMAN_USER/.Xauthority}" \
      DBUS_SESSION_BUS_ADDRESS="${dbus:-unix:path=/run/user/$(id -u "$HUMAN_USER")/bus}" \
      "$@"
    return $?
  fi

  [ -n "${DISPLAY:-}" ] || return 1
  uid="$(id -u "$HUMAN_USER" 2>/dev/null || true)"
  [ -n "$uid" ] || return 1
  [ -S "/run/user/$uid/bus" ] || return 1
  sudo -u "$HUMAN_USER" env \
    DISPLAY="$DISPLAY" \
    XAUTHORITY="/home/$HUMAN_USER/.Xauthority" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    "$@"
}

xfconf_get() {
  session_run xfconf-query -c "$1" -p "$2" 2>/dev/null || true
}

xfconf_set() {
  local channel="$1" path="$2" type="$3" value="$4" current
  current="$(xfconf_get "$channel" "$path")"
  if [ "$current" = "$value" ]; then
    return 0
  fi
  session_run xfconf-query -c "$channel" -p "$path" -s "$value" >/dev/null 2>&1 ||
    session_run xfconf-query -c "$channel" -p "$path" -n -t "$type" -s "$value" >/dev/null 2>&1 ||
    true
  SESSION_CHANGED=1
}

install_assets() {
  local logo_b64
  [ -f "$LOGO_FILE" ] || return 0
  install -d "$WALLPAPER_DIR" "$GUI_ASSET_DIR"
  logo_b64="$(base64 -w0 "$LOGO_FILE")"
  cat >"$LIGHT_WALLPAPER" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="3840" height="2160" viewBox="0 0 3840 2160">
  <defs>
    <filter id="logo"><feColorMatrix type="matrix" values="0 0 0 0 0.07 0 0 0 0 0.065 0 0 0 0 0.055 0 0 0 0.30 0"/></filter>
  </defs>
  <rect width="3840" height="2160" fill="#b7b1a5"/>
  <image href="data:image/png;base64,$logo_b64" x="1320" y="480" width="1200" height="1200" preserveAspectRatio="xMidYMid meet" filter="url(#logo)"/>
</svg>
EOF
  cat >"$DARK_WALLPAPER" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="3840" height="2160" viewBox="0 0 3840 2160">
  <defs>
    <filter id="logo"><feColorMatrix type="matrix" values="0 0 0 0 0.94 0 0 0 0 0.91 0 0 0 0 0.84 0 0 0 0.18 0"/></filter>
  </defs>
  <rect width="3840" height="2160" fill="#2d2b27"/>
  <image href="data:image/png;base64,$logo_b64" x="1320" y="480" width="1200" height="1200" preserveAspectRatio="xMidYMid meet" filter="url(#logo)"/>
</svg>
EOF
  cat >"$LIGHT_MENU_ICON" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
  <defs>
    <filter id="logo"><feColorMatrix type="matrix" values="0 0 0 0 0.10 0 0 0 0 0.10 0 0 0 0 0.09 0 0 0 1 0"/></filter>
  </defs>
  <image href="data:image/png;base64,$logo_b64" x="6" y="6" width="84" height="84" preserveAspectRatio="xMidYMid meet" filter="url(#logo)"/>
</svg>
EOF
  cat >"$DARK_MENU_ICON" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
  <defs>
    <filter id="logo"><feColorMatrix type="matrix" values="0 0 0 0 0.94 0 0 0 0 0.91 0 0 0 0 0.84 0 0 0 1 0"/></filter>
  </defs>
  <image href="data:image/png;base64,$logo_b64" x="6" y="6" width="84" height="84" preserveAspectRatio="xMidYMid meet" filter="url(#logo)"/>
</svg>
EOF
  chmod 0644 "$LIGHT_WALLPAPER" "$DARK_WALLPAPER" "$LIGHT_MENU_ICON" "$DARK_MENU_ICON"
}

theme_css() {
  local mode="$1" fg panel panel_hover panel_active menu selected
  if [ "$mode" = light ]; then
    fg="#1f1d1a"
    panel="#f7f7f4"
    panel_hover="#ebe9e2"
    panel_active="#dedbd1"
    menu="#f7f7f4"
    selected="#d8d5cc"
  else
    fg="#f0e9d8"
    panel="#2d2b27"
    panel_hover="#3a362f"
    panel_active="#484238"
    menu="#302d28"
    selected="#6b604e"
  fi
  cat <<EOF

/* vEGPU owned XFCE GTK3 appearance. */
* {
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background,
.xfce4-panel.background.horizontal,
.xfce4-panel.background.vertical {
  background-color: $panel;
  background-image: none;
  color: $fg;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background *,
.xfce4-panel.background label,
.xfce4-panel.background button label,
.xfce4-panel.background #applicationmenu-button label,
.xfce4-panel.background .tasklist button label {
  color: $fg;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background button,
.xfce4-panel.background button.flat,
.xfce4-panel.background #applicationmenu-button,
.xfce4-panel.background .tasklist button,
.xfce4-panel.background .window-button {
  background-color: $panel;
  background-image: none;
  border-color: transparent;
  box-shadow: none;
  color: $fg;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

.xfce4-panel.background button:hover,
.xfce4-panel.background #applicationmenu-button:hover,
.xfce4-panel.background .tasklist button:hover,
.xfce4-panel.background .window-button:hover {
  background-color: $panel_hover;
  background-image: none;
  border-color: $selected;
  box-shadow: none;
  color: $fg;
}

.xfce4-panel.background button:checked,
.xfce4-panel.background button:active,
.xfce4-panel.background #applicationmenu-button:checked,
.xfce4-panel.background #applicationmenu-button:active,
.xfce4-panel.background .tasklist button:checked,
.xfce4-panel.background .tasklist button:active,
.xfce4-panel.background .window-button:checked,
.xfce4-panel.background .window-button:active {
  background-color: $panel_active;
  background-image: none;
  border-color: $selected;
  box-shadow: none;
  color: $fg;
}

.xfce4-panel.background menu,
.xfce4-panel.background menuitem {
  background-color: $menu;
  background-image: none;
  color: $fg;
  text-shadow: none;
  -gtk-icon-shadow: none;
}

XfdesktopIconView.view,
XfdesktopIconView.view *,
XfdesktopIconView.view label,
XfdesktopIconView.view .label {
  color: $fg;
  text-shadow: none;
  -gtk-icon-shadow: none;
  -XfdesktopIconView-label-alpha: 0;
  -XfdesktopIconView-selected-label-alpha: 90;
  -XfdesktopIconView-shadow-x-offset: 0;
  -XfdesktopIconView-shadow-y-offset: 0;
  -XfdesktopIconView-selected-shadow-x-offset: 0;
  -XfdesktopIconView-selected-shadow-y-offset: 0;
}
EOF
}

install_theme_variant() {
  local name="$1" base="$2" mode="$3" tmp css
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
  theme_css "$mode" >>"$css"
  rm -rf "/usr/share/themes/$name"
  mv "$tmp" "/usr/share/themes/$name"
  chmod -R a+rX "/usr/share/themes/$name"
}

install_themes() {
  install_theme_variant vEGPU-light Greybird light
  install_theme_variant vEGPU-dark Greybird-dark dark
}

gtk_user_css() {
  local fg
  fg="$(desktop_text_color)"
  cat <<EOF
/* vEGPU owned GTK session policy. */
* {
  text-shadow: none;
  -gtk-icon-shadow: none;
}

XfdesktopIconView.view,
XfdesktopIconView.view *,
XfdesktopIconView.view label,
XfdesktopIconView.view .label {
  color: $fg;
  text-shadow: none;
  -gtk-icon-shadow: none;
  -XfdesktopIconView-label-alpha: 0;
  -XfdesktopIconView-selected-label-alpha: 90;
  -XfdesktopIconView-shadow-x-offset: 0;
  -XfdesktopIconView-shadow-y-offset: 0;
  -XfdesktopIconView-selected-shadow-x-offset: 0;
  -XfdesktopIconView-selected-shadow-y-offset: 0;
}
EOF
}

xsettings_xml() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="$(theme_name)"/>
    <property name="IconThemeName" type="string" value="Adwaita"/>
  </property>
</channel>
EOF
}

desktop_xml() {
  local wallpaper
  wallpaper="$(wallpaper_path)"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitordefault" type="empty">
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
    </property>
  </property>
  <property name="desktop-icons" type="empty">
    <property name="style" type="int" value="2"/>
    <property name="center-text" type="bool" value="true"/>
  </property>
</channel>
EOF
}

panel_xml() {
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
      <property name="button-icon" type="string" value="$(menu_icon_path)"/>
      <property name="show-button-title" type="bool" value="true"/>
      <property name="button-title" type="string" value="Applications"/>
    </property>
    <property name="plugin-2" type="string" value="tasklist"/>
  </property>
</channel>
EOF
}

session_xml() {
  cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-session" version="1.0">
  <property name="general" type="empty">
    <property name="SaveOnExit" type="bool" value="false"/>
    <property name="LockCommand" type="string" value=""/>
  </property>
</channel>
EOF
}

install_xfconf_defaults() {
  local home config_dir
  home="$(human_home)"
  [ -n "$home" ] || return 0
  config_dir="$home/.config/xfce4/xfconf/xfce-perchannel-xml"
  install -d "$GLOBAL_XFCONF_DIR" /etc/xdg/xfce4/panel
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" "$config_dir" "$home/.config/gtk-3.0"

  xsettings_xml | write_root_file "$GLOBAL_XFCONF_DIR/xsettings.xml"
  xsettings_xml | write_user_file "$config_dir/xsettings.xml"
  desktop_xml | write_root_file "$GLOBAL_XFCONF_DIR/xfce4-desktop.xml"
  desktop_xml | write_user_file "$config_dir/xfce4-desktop.xml"
  panel_xml | write_root_file "$GLOBAL_PANEL_DEFAULT"
  panel_xml | write_user_file "$config_dir/xfce4-panel.xml"
  session_xml | write_root_file "$GLOBAL_XFCONF_DIR/xfce4-session.xml"
  session_xml | write_user_file "$config_dir/xfce4-session.xml"
  gtk_user_css | write_user_file "$home/.config/gtk-3.0/gtk.css"
}

install_autostarts() {
  local home autostart
  home="$(human_home)"
  [ -n "$home" ] || return 0
  autostart="$home/.config/autostart"
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" "$autostart"
  cat >"$autostart/vegpu-appearance.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=vEGPU Appearance
Exec=/usr/local/libexec/vegpu/customization.sh apply-session
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOF
  chown "$HUMAN_USER:$HUMAN_USER" "$autostart/vegpu-appearance.desktop"
}

clear_saved_sessions() {
  local home
  home="$(human_home)"
  [ -n "$home" ] || return 0
  rm -rf "$home/.cache/sessions"
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" "$home/.cache/sessions"
}

install_backdrop_fallbacks() {
  local wallpaper target
  wallpaper="$(wallpaper_path)"
  [ -f "$wallpaper" ] || return 0
  install -d "$WALLPAPER_DIR" /usr/share/backgrounds/xfce /usr/share/xfce4/backdrops
  cp -f "$wallpaper" "$WALLPAPER_DIR/current.svg"
  for target in \
    /usr/share/backgrounds/greybird.svg \
    /usr/share/xfce4/backdrops/greybird-wall.svg \
    /usr/share/backgrounds/xfce/xfce-x.svg; do
    [ -d "$(dirname "$target")" ] || continue
    cp -f "$wallpaper" "$target"
    chmod 0644 "$target"
  done
}

install_system() {
  install -d "$STATE_DIR"
  install_assets
  install_themes
  install_backdrop_fallbacks
  install_xfconf_defaults
  install_autostarts
  clear_saved_sessions
}

connected_outputs() {
  session_run /usr/bin/timeout 4s xrandr --query 2>/dev/null |
    awk '$2 == "connected" { print $1 }' || true
}

wallpaper_targets() {
  {
    printf '%s\n' monitordefault
    connected_outputs | awk 'NF { print "monitor" $1 }'
  } | awk 'NF && !seen[$0]++'
}

apply_wallpaper() {
  local wallpaper monitor base
  wallpaper="$(wallpaper_path)"
  [ -f "$wallpaper" ] || return 0
  while IFS= read -r monitor; do
    [ -n "$monitor" ] || continue
    base="/backdrop/screen0/$monitor"
    xfconf_set xfce4-desktop "$base/color-style" int 0
    xfconf_set xfce4-desktop "$base/image-show" bool true
    xfconf_set xfce4-desktop "$base/image-path" string "$wallpaper"
    xfconf_set xfce4-desktop "$base/last-image" string "$wallpaper"
    xfconf_set xfce4-desktop "$base/last-single-image" string "$wallpaper"
    xfconf_set xfce4-desktop "$base/workspace0/color-style" int 0
    xfconf_set xfce4-desktop "$base/workspace0/image-style" int 5
    xfconf_set xfce4-desktop "$base/workspace0/last-image" string "$wallpaper"
  done < <(wallpaper_targets)
}

apply_session() {
  local theme menu_icon
  SESSION_CHANGED=0
  theme="$(theme_name)"
  menu_icon="$(menu_icon_path)"
  xfconf_set xsettings /Net/ThemeName string "$theme"
  xfconf_set xsettings /Net/IconThemeName string Adwaita
  xfconf_set xfce4-session /general/SaveOnExit bool false
  xfconf_set xfce4-session /general/LockCommand string ""
  xfconf_set xfce4-desktop /desktop-icons/style int 2
  xfconf_set xfce4-desktop /desktop-icons/center-text bool true
  xfconf_set xfce4-panel /plugins/plugin-1/button-icon string "$menu_icon"
  xfconf_set xfce4-panel /plugins/plugin-1/show-button-title bool true
  xfconf_set xfce4-panel /plugins/plugin-1/button-title string Applications
  apply_wallpaper
  if [ "$SESSION_CHANGED" -eq 1 ]; then
    session_run /usr/bin/timeout 4s xfdesktop --reload >/dev/null 2>&1 || true
  fi
}

best_mode_for_output() {
  session_run /usr/bin/timeout 4s xrandr --query 2>/dev/null | awk '
    function abs(value) { return value < 0 ? -value : value }
    $2 == "connected" {
      output = $1
      output_aspect = 0
      for (i = 1; i <= NF - 2; i++) {
        if ($i ~ /^[0-9]+mm$/ && $(i + 1) == "x" && $(i + 2) ~ /^[0-9]+mm$/) {
          phys_w = $i
          phys_h = $(i + 2)
          gsub(/mm$/, "", phys_w)
          gsub(/mm$/, "", phys_h)
          if (phys_w + 0 > 0 && phys_h + 0 > 0) output_aspect = (phys_w + 0) / (phys_h + 0)
        }
      }
      next
    }
    output != "" && /^[[:space:]]+[0-9]+x[0-9]+[[:space:]]/ {
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
      aspect = height > 0 ? width / height : 0
      penalty = output_aspect > 0 && aspect > 0 ? abs(output_aspect - aspect) * 10000000 : 0
      score = area - penalty + preferred * 100000 + current * 10 + refresh
      if (score > best[output]) {
        best[output] = score
        best_mode[output] = mode
      }
    }
    END {
      for (name in best_mode) print name " " best_mode[name]
    }'
}

apply_display() {
  local output mode
  while read -r output mode; do
    [ -n "${output:-}" ] && [ -n "${mode:-}" ] || continue
    session_run xrandr --output "$output" --mode "$mode" --primary >/dev/null 2>&1 || true
  done < <(best_mode_for_output)
  if command -v vegpu-scaling >/dev/null 2>&1; then
    session_run vegpu-scaling --display "${DISPLAY:-:0}" reapply --quiet >/dev/null 2>&1 || true
  fi
}

disable_idle() {
  /usr/bin/timeout 15s systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
  /usr/bin/timeout 15s systemctl disable --now light-locker xfce4-screensaver xscreensaver >/dev/null 2>&1 || true
  install -d /etc/systemd/logind.conf.d
  cat >/etc/systemd/logind.conf.d/90-vegpu-no-sleep.conf <<'EOF'
[Login]
IdleAction=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOF
  /usr/bin/timeout 15s systemctl restart systemd-logind >/dev/null 2>&1 || true
  xfconf_set xfce4-power-manager /xfce4-power-manager/presentation-mode bool true
  xfconf_set xfce4-power-manager /xfce4-power-manager/blank-on-ac int 0
  xfconf_set xfce4-power-manager /xfce4-power-manager/blank-on-battery int 0
  xfconf_set xfce4-power-manager /xfce4-power-manager/dpms-enabled bool false
  session_run xset s off -dpms s noblank >/dev/null 2>&1 || true
}

usage() {
  printf 'usage: %s {write-prefs|install-system|install-global-defaults|apply-boot-defaults|apply-session|apply-session-appearance|apply-display|apply-primary-display|disable-idle|create-assets}\n' "$0" >&2
}

main() {
  case "${1:-}" in
    write-prefs)
      write_prefs
      ;;
    create-assets)
      install_assets
      ;;
    install-system|install-global-defaults)
      install_system
      ;;
    apply-boot-defaults)
      install_system
      disable_idle
      apply_session || true
      ;;
    apply-session|apply-session-appearance)
      apply_session
      ;;
    apply-display|apply-primary-display)
      apply_display
      ;;
    disable-idle)
      disable_idle
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"

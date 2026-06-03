#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

STATE_DIR=/var/lib/vegpu
GUI_READY_MARKER="$STATE_DIR/gui-desktop.ready"
APPEARANCE_MARKER="$STATE_DIR/gui-appearance.sha256"
SHARE=/mnt/vegpu-share
HUMAN_USER="${VEGPU_DISPLAY_USER:-vegpu}"
CUSTOMIZATION_SCRIPT=/usr/local/libexec/vegpu/customization.sh
DISPLAY_HELPER=/usr/local/sbin/vegpu-display-mode-helper
DISPLAY_CONTROL=/usr/local/bin/vegpu-display-control

log() {
  printf '[gui-ensure] %s\n' "$*" >&2
}

apt_get() {
  local attempt output code
  output=""
  code=1
  for attempt in $(seq 1 120); do
    set +e
    output="$(apt-get -o DPkg::Lock::Timeout=600 -o APT::Get::Lock-Timeout=600 "$@" 2>&1)"
    code=$?
    set -e
    if [ "$code" -eq 0 ]; then
      [ -n "$output" ] && printf '%s\n' "$output" >&2
      return 0
    fi
    if printf '%s\n' "$output" | grep -qiE 'Could not get lock|Unable to lock directory|Unable to acquire|is held by process|is another process using it|dpkg frontend lock'; then
      log "apt lock busy; waiting for current package operation ($attempt/120)"
      sleep 5
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$code"
  done
  printf '%s\n' "$output" >&2
  return "$code"
}

install_file_if_changed() {
  local source="$1" destination="$2" mode="$3"
  if [ -f "$destination" ] && cmp -s "$source" "$destination"; then
    chmod "$mode" "$destination"
    return 0
  fi
  install -D -m "$mode" "$source" "$destination"
}

write_root_file_if_changed() {
  local destination="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  install_file_if_changed "$tmp" "$destination" "$mode"
  rm -f "$tmp"
}

script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P
}

install_customization_script() {
  local source_path
  install -d "$(dirname "$CUSTOMIZATION_SCRIPT")"
  source_path="${VEGPU_CUSTOMIZATION_SOURCE:-$(script_dir)/customization.sh}"
  if [ -f "$source_path" ]; then
    install -m 0755 "$source_path" "$CUSTOMIZATION_SCRIPT"
    return 0
  fi
  if [ -x "$CUSTOMIZATION_SCRIPT" ]; then
    return 0
  fi
  printf 'Missing vEGPU GUI customization script: %s\n' "$source_path" >&2
  exit 1
}

run_customization() {
  [ -x "$CUSTOMIZATION_SCRIPT" ] || {
    printf 'Missing vEGPU GUI customization script: %s\n' "$CUSTOMIZATION_SCRIPT" >&2
    exit 1
  }
  "$CUSTOMIZATION_SCRIPT" "$@"
}

desktop_stack_ready() {
  [ -f "$GUI_READY_MARKER" ] &&
    command -v startxfce4 >/dev/null 2>&1 &&
    command -v xfconf-query >/dev/null 2>&1 &&
    command -v xfdesktop >/dev/null 2>&1 &&
    command -v lightdm >/dev/null 2>&1 &&
    command -v spice-vdagent >/dev/null 2>&1 &&
    command -v thunar >/dev/null 2>&1 &&
    python3 -c 'import gi' >/dev/null 2>&1
}

install_desktop_stack() {
  if desktop_stack_ready; then
    return 0
  fi

  log "installing XFCE desktop stack"
  apt_get update
  apt_get install -y \
    dbus-x11 \
    lightdm \
    lightdm-gtk-greeter \
    gvfs-backends \
    gvfs-fuse \
    librsvg2-common \
    mesa-utils \
    libgl1-mesa-dri \
    qemu-guest-agent \
    spice-vdagent \
    network-manager \
    pipewire \
    pipewire-pulse \
    pipewire-alsa \
    wireplumber \
    jq \
    gir1.2-gtk-3.0 \
    python3 \
    python3-gi \
    thunar \
    xdg-utils \
    x11-xserver-utils \
    xauth \
    xinput \
    xserver-xorg-core \
    xserver-xorg-input-libinput \
    xfce4-panel \
    xfce4-power-manager \
    xfce4-session \
    xfce4-terminal \
    xfconf \
    xfdesktop4 \
    xfwm4 \
    adwaita-icon-theme \
    greybird-gtk-theme

  install -d "$STATE_DIR"
  touch "$GUI_READY_MARKER"
}

configure_desktop_network() {
  command -v nmcli >/dev/null 2>&1 || return 0

  install -d /etc/NetworkManager/conf.d /etc/NetworkManager/system-connections
  write_root_file_if_changed /etc/NetworkManager/conf.d/90-vegpu-managed.conf <<'EOF'
[ifupdown]
managed=true

[keyfile]
unmanaged-devices=none
EOF

  write_root_file_if_changed /etc/NetworkManager/system-connections/vegpu-vmnet.nmconnection 0600 <<'EOF'
[connection]
id=vEGPU vmnet
uuid=8a6021b7-6c4b-4fd5-9c28-2b09d0f5e100
type=ethernet
interface-name=enp0s3
autoconnect=true
autoconnect-priority=100

[ethernet]
mac-address=DE:AD:BE:EF:10:01

[ipv4]
method=manual
addresses=172.29.253.100/24
gateway=172.29.253.1
dns=172.29.253.1;1.1.1.1;
may-fail=false

[ipv6]
method=disabled
EOF

  systemctl enable NetworkManager >/dev/null 2>&1 || true
  systemctl is-active --quiet NetworkManager >/dev/null 2>&1 || systemctl start NetworkManager >/dev/null 2>&1 || true
  nmcli connection reload >/dev/null 2>&1 || true
  nmcli device set enp0s3 managed yes >/dev/null 2>&1 || true
  nmcli connection up "vEGPU vmnet" ifname enp0s3 >/dev/null 2>&1 || true
}

repair_share_access() {
  local share_gid share_group
  usermod -aG dialout "$HUMAN_USER" 2>/dev/null || true
  usermod -aG dialout vegpuctl 2>/dev/null || true
  if /usr/bin/timeout 2s test -e "$SHARE" 2>/dev/null; then
    share_gid="$(/usr/bin/timeout 2s stat -c '%g' "$SHARE" 2>/dev/null || true)"
    share_group="$(getent group "$share_gid" 2>/dev/null | cut -d: -f1 || true)"
    if [ -n "$share_group" ]; then
      usermod -aG "$share_group" "$HUMAN_USER" 2>/dev/null || true
      usermod -aG "$share_group" vegpuctl 2>/dev/null || true
    fi
  fi
}

repair_desktop_links() {
  local home tmp
  home="/home/$HUMAN_USER"
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" \
    "$home/Desktop" \
    "$home/.config/gtk-3.0" \
    "$home/.config/autostart" \
    "$home/.local/share" \
    "$home/.local/share/gvfs-metadata" \
    "$home/.local/share/applications"

  rm -f /usr/local/bin/vegpu-open-mac-share \
    "$home/Desktop/Mac Share.desktop" \
    "$home/.local/share/applications/vegpu-mac-share.desktop"
  rm -rf "$home/Mac Share" "$home/Desktop/Mac Share"

  ln -sfn "$SHARE" "$home/Mac Share"
  ln -sfn "$SHARE" "$home/Desktop/Mac Share"
  chown -h "$HUMAN_USER:$HUMAN_USER" "$home/Mac Share" "$home/Desktop/Mac Share"

  if [ -f "$home/.config/gtk-3.0/bookmarks" ]; then
    tmp="$(mktemp)"
    awk -v raw="file://$SHARE Mac Share" '$0 != raw { print }' "$home/.config/gtk-3.0/bookmarks" >"$tmp"
    install -o "$HUMAN_USER" -g "$HUMAN_USER" -m 0644 "$tmp" "$home/.config/gtk-3.0/bookmarks"
    rm -f "$tmp"
  fi
}

install_lightdm_autologin() {
  install -d /etc/lightdm/lightdm.conf.d
  write_root_file_if_changed /etc/lightdm/lightdm.conf.d/90-vegpu-autologin.conf <<EOF
[Seat:*]
autologin-user=$HUMAN_USER
autologin-user-timeout=0
user-session=xfce
greeter-session=lightdm-gtk-greeter
EOF
}

install_spice_agent_autostart() {
  local home
  home="/home/$HUMAN_USER"
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" "$home/.config/autostart"
  cat >"$home/.config/autostart/spice-vdagent.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=SPICE Agent
Exec=/usr/bin/spice-vdagent
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOF
  chown "$HUMAN_USER:$HUMAN_USER" "$home/.config/autostart/spice-vdagent.desktop"
}

appearance_fingerprint() {
  {
    sha256sum /etc/vegpu/gui-prefs.conf 2>/dev/null || true
    sha256sum "$CUSTOMIZATION_SCRIPT" 2>/dev/null || true
    sha256sum /usr/share/vegpu/gui/vEGPU-logo-transparent.png 2>/dev/null || true
  } | sha256sum | awk '{ print $1 }'
}

install_appearance_once() {
  local fingerprint old
  run_customization write-prefs
  fingerprint="$(appearance_fingerprint)"
  old="$(cat "$APPEARANCE_MARKER" 2>/dev/null || true)"
  if [ "$fingerprint" = "$old" ]; then
    return 0
  fi

  log "installing vEGPU XFCE appearance defaults"
  run_customization install-system
  run_customization disable-idle || true
  run_customization apply-session || true
  install -d "$STATE_DIR"
  printf '%s\n' "$fingerprint" >"$APPEARANCE_MARKER"
}

install_display_control() {
  local tmp
  install -d /usr/local/sbin /usr/local/bin /etc/sudoers.d /etc/systemd/system

  tmp="$(mktemp)"
  cat >"$tmp" <<'HELPER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

MODE_DIR=/etc/vegpu
MODE_FILE="$MODE_DIR/display-mode.conf"
XORG_CONF=/etc/X11/xorg.conf.d/20-vegpu-virtio-display.conf
NO_IDLE_CONF=/etc/X11/xorg.conf.d/90-vegpu-no-idle.conf
CUSTOMIZATION_SCRIPT=/usr/local/libexec/vegpu/customization.sh
SESSION_ROOT=/run/vegpu-display-sessions
SESSION_STATE_ROOT=/var/lib/vegpu/display-sessions
DISPLAY_USER="${VEGPU_DISPLAY_USER:-vegpu}"

json_value() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

run_customization() {
  [ -x "$CUSTOMIZATION_SCRIPT" ] || {
    printf 'Missing vEGPU GUI customization script: %s\n' "$CUSTOMIZATION_SCRIPT" >&2
    exit 1
  }
  "$CUSTOMIZATION_SCRIPT" "$@"
}

write_root_file_if_changed() {
  local destination="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if ! [ -f "$destination" ] || ! cmp -s "$tmp" "$destination"; then
    install -D -m "$mode" "$tmp" "$destination"
  fi
  rm -f "$tmp"
}

normalize_bdf() {
  local raw="$1" domain bus slot func
  raw="${raw#pci:}"
  raw="${raw,,}"
  IFS=':.' read -r domain bus slot func <<BDF_EOF
$raw
BDF_EOF
  domain="${domain:-0000}"
  bus="${bus:-00}"
  slot="${slot:-00}"
  func="${func:-0}"
  domain="${domain: -4}"
  printf '%04x:%02x:%02x.%d\n' "$((16#$domain))" "$((16#$bus))" "$((16#$slot))" "$((10#$func))"
}

xorg_bus_id_from_bdf() {
  local bdf="$1" domain bus slot func
  IFS=':.' read -r domain bus slot func <<BDF_EOF
$bdf
BDF_EOF
  printf 'PCI:%d:%d:%d\n' "$((16#$bus))" "$((16#$slot))" "$((10#$func))"
}

detect_virtio_gpu_bdf() {
  local card vendor driver
  for card in /sys/class/drm/card*; do
    [ -e "$card/device/vendor" ] || continue
    vendor="$(cat "$card/device/vendor" 2>/dev/null || true)"
    driver="$(basename "$(readlink -f "$card/device/driver" 2>/dev/null)" 2>/dev/null || true)"
    if [ "$vendor" = "0x1af4" ] || [ "$driver" = "virtio-pci" ] || [ "$driver" = "virtio_gpu" ]; then
      basename "$(readlink -f "$card/device")"
      return 0
    fi
  done
  printf '%s\n' "0000:00:06.0"
}

validate_nvidia_bdf() {
  local bdf="$1"
  [ -e "/sys/bus/pci/devices/$bdf/vendor" ] || {
    printf 'No PCI device found at %s\n' "$bdf" >&2
    return 1
  }
  [ "$(cat "/sys/bus/pci/devices/$bdf/vendor" 2>/dev/null || true)" = "0x10de" ] || {
    printf 'PCI device %s is not an NVIDIA device\n' "$bdf" >&2
    return 1
  }
}

gpu_valid_for_bdf() {
  local bdf="$1"
  [ -e "/sys/bus/pci/devices/$bdf/vendor" ] || return 1
  [ "$(cat "/sys/bus/pci/devices/$bdf/vendor" 2>/dev/null || true)" = "0x10de" ]
}

gpu_rows() {
  nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv,noheader,nounits 2>/dev/null |
    awk -F', *' 'NF >= 3 { printf "%s\t%s\t%s\n", $1, $2, $3 }'
}

write_no_idle_flags() {
  install -d /etc/X11/xorg.conf.d
  write_root_file_if_changed "$NO_IDLE_CONF" <<'CONF'
Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection
CONF
}

write_spice_xorg() {
  local virtio_busid="$1"
  install -d /etc/X11/xorg.conf.d "$MODE_DIR"
  write_root_file_if_changed "$XORG_CONF" <<CONF
Section "ServerFlags"
    Option "AutoAddGPU" "false"
    Option "AutoBindGPU" "false"
EndSection

Section "Device"
    Identifier "vEGPU Virtio Display"
    Driver "modesetting"
    BusID "$virtio_busid"
    Option "PrimaryGPU" "true"
    Option "DRI" "3"
EndSection

Section "Screen"
    Identifier "vEGPU Screen"
    Device "vEGPU Virtio Display"
EndSection

Section "ServerLayout"
    Identifier "vEGPU Layout"
    Screen "vEGPU Screen"
EndSection
CONF
}

write_external_xorg() {
  local nvidia_busid="$1"
  install -d /etc/X11/xorg.conf.d "$MODE_DIR"
  write_root_file_if_changed "$XORG_CONF" <<CONF
Section "ServerFlags"
    Option "AutoAddGPU" "false"
    Option "AutoBindGPU" "false"
EndSection

Section "Device"
    Identifier "vEGPU External NVIDIA"
    Driver "nvidia"
    BusID "$nvidia_busid"
    Option "AllowEmptyInitialConfiguration" "true"
    Option "PrimaryGPU" "true"
EndSection

Section "Screen"
    Identifier "vEGPU External Screen"
    Device "vEGPU External NVIDIA"
EndSection

Section "ServerLayout"
    Identifier "vEGPU Layout"
    Screen "vEGPU External Screen"
EndSection
CONF
}

write_mode_file() {
  install -d "$MODE_DIR"
  cat >"$MODE_FILE"
  chmod 0644 "$MODE_FILE"
}

mode_value() {
  local key="$1"
  [ -f "$MODE_FILE" ] || return 0
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$MODE_FILE"
}

current_display_mode() {
  mode_value VEGPU_DISPLAY_MODE
}

configure_spice_without_restart() {
  local virtio_bdf
  virtio_bdf="$(detect_virtio_gpu_bdf)"
  write_spice_xorg "$(xorg_bus_id_from_bdf "$virtio_bdf")"
  write_no_idle_flags
}

configure_external_without_restart() {
  local nvidia_bdf="$1"
  validate_nvidia_bdf "$nvidia_bdf"
  write_external_xorg "$(xorg_bus_id_from_bdf "$nvidia_bdf")"
  write_no_idle_flags
}

configure_current_without_restart() {
  local mode nvidia_bdf
  mode="$(current_display_mode)"
  nvidia_bdf="$(mode_value VEGPU_NVIDIA_BDF)"
  if [ "$mode" = "external-primary" ] && [ -n "$nvidia_bdf" ] && gpu_valid_for_bdf "$nvidia_bdf"; then
    configure_external_without_restart "$nvidia_bdf"
  else
    configure_spice_without_restart
  fi
}

restart_lightdm() {
  /usr/bin/timeout 20s systemctl restart lightdm >/dev/null 2>&1 || true
}

session_id_for_bdf() {
  printf 'gpu-%s\n' "$(printf '%s' "$1" | sed 's/[:.]/-/g')"
}

session_dir_for_id() {
  printf '%s/%s\n' "$SESSION_ROOT" "$1"
}

session_state_dir_for_id() {
  printf '%s/%s\n' "$SESSION_STATE_ROOT" "$1"
}

session_env_file_for_id() {
  printf '%s/session.env\n' "$(session_state_dir_for_id "$1")"
}

session_load_env() {
  local id="$1" env_file
  env_file="$(session_env_file_for_id "$id")"
  [ -f "$env_file" ] || return 1
  # shellcheck disable=SC1090
  . "$env_file"
}

session_index_for_bdf() {
  local bdf="$1" idx name raw_bdf row_bdf
  while IFS=$'\t' read -r idx name raw_bdf; do
    [ -n "${raw_bdf:-}" ] || continue
    row_bdf="$(normalize_bdf "$raw_bdf" 2>/dev/null || true)"
    if [ "$row_bdf" = "$bdf" ]; then
      printf '%s\n' "$idx"
      return 0
    fi
  done < <(gpu_rows || true)
  return 1
}

session_name_for_bdf() {
  local bdf="$1" idx name raw_bdf row_bdf
  while IFS=$'\t' read -r idx name raw_bdf; do
    [ -n "${raw_bdf:-}" ] || continue
    row_bdf="$(normalize_bdf "$raw_bdf" 2>/dev/null || true)"
    if [ "$row_bdf" = "$bdf" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(gpu_rows || true)
  printf '%s\n' "NVIDIA GPU"
}

session_display_for_index() {
  local idx="${1:-0}"
  case "$idx" in ''|*[!0-9]*) idx=0 ;; esac
  printf ':%d\n' "$((10 + idx))"
}

session_pid_alive() {
  local pid_file="$1" pid
  [ -f "$pid_file" ] || return 1
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1
}

session_xorg_running() {
  local id="$1" dir
  dir="$(session_dir_for_id "$id")"
  session_pid_alive "$dir/xorg.pid"
}

session_clear_stale_display_lock() {
  local display="$1" number pid
  number="${display#:}"
  case "$number" in ''|*[!0-9]*) return 0 ;; esac
  if [ -f "/tmp/.X${number}-lock" ]; then
    pid="$(tr -d ' ' <"/tmp/.X${number}-lock" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  fi
  rm -f "/tmp/.X${number}-lock" "/tmp/.X11-unix/X${number}"
}

session_run_user() {
  local display="$1" xauthority="$2" uid bus
  shift 2
  uid="$(id -u "$DISPLAY_USER" 2>/dev/null || true)"
  bus="/run/user/$uid/bus"
  runuser -u "$DISPLAY_USER" -- env \
    DISPLAY="$display" \
    XAUTHORITY="$xauthority" \
    HOME="/home/$DISPLAY_USER" \
    USER="$DISPLAY_USER" \
    LOGNAME="$DISPLAY_USER" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$bus}" \
    "$@"
}

primary_session_env() {
  local target_xauthority pid envlines display xauthority dbus
  target_xauthority="/home/$DISPLAY_USER/.Xauthority"
  for pid in $(pgrep -u "$DISPLAY_USER" xfce4-session 2>/dev/null || true) \
             $(pgrep -u "$DISPLAY_USER" xfce4-panel 2>/dev/null || true) \
             $(pgrep -u "$DISPLAY_USER" xfdesktop 2>/dev/null || true); do
    [ -r "/proc/$pid/environ" ] || continue
    envlines="$(tr '\0' '\n' <"/proc/$pid/environ")"
    display="$(printf '%s\n' "$envlines" | awk -F= '$1 == "DISPLAY" { print substr($0, index($0, "=") + 1); exit }')"
    [ -n "$display" ] || continue
    xauthority="$(printf '%s\n' "$envlines" | awk -F= '$1 == "XAUTHORITY" { print substr($0, index($0, "=") + 1); exit }')"
    xauthority="${xauthority:-$target_xauthority}"
    [ "$xauthority" = "$target_xauthority" ] || continue
    dbus="$(printf '%s\n' "$envlines" | awk -F= '$1 == "DBUS_SESSION_BUS_ADDRESS" { print substr($0, index($0, "=") + 1); exit }')"
    printf '%s\t%s\t%s\n' "$display" "$xauthority" "$dbus"
    return 0
  done
  return 1
}

session_xinput_ids_by_name() {
  local display="$1" xauthority="$2" name="$3"
  command -v xinput >/dev/null 2>&1 || return 0
  DISPLAY="$display" XAUTHORITY="$xauthority" xinput --list --short 2>/dev/null |
    awk -v name="$name" 'index($0, name) && match($0, /id=[0-9]+/) { print substr($0, RSTART + 3, RLENGTH - 3) }' || true
}

session_xinput_master_id() {
  local display="$1" xauthority="$2" kind="$3"
  command -v xinput >/dev/null 2>&1 || return 0
  DISPLAY="$display" XAUTHORITY="$xauthority" xinput --list --short 2>/dev/null |
    awk -v kind="$kind" '$0 ~ "Virtual core " kind && $0 ~ "\\[master " kind {
      if (match($0, /id=[0-9]+/)) {
        print substr($0, RSTART + 3, RLENGTH - 3)
        exit
      }
    }' || true
}

session_xinput_device_enabled() {
  local display="$1" xauthority="$2" id="$3" value
  value="$(DISPLAY="$display" XAUTHORITY="$xauthority" xinput list-props "$id" 2>/dev/null |
    awk -F: '/Device Enabled/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' || true)"
  [ "$value" = "1" ]
}

session_xinput_device_attached() {
  local display="$1" xauthority="$2" id="$3"
  DISPLAY="$display" XAUTHORITY="$xauthority" xinput --list --short 2>/dev/null |
    awk -v needle="id=$id" '
      index($0, needle) {
        found = 1
        attached = index($0, "floating slave") ? 0 : index($0, "[slave") ? 1 : 0
      }
      END { exit(found && attached ? 0 : 1) }
    '
}

session_route_named_input() {
  local display="$1" xauthority="$2" name="$3" target="$4" role="$5" ids id
  ids="$(session_xinput_ids_by_name "$display" "$xauthority" "$name")"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$role" in
      active)
        [ -n "$target" ] && DISPLAY="$display" XAUTHORITY="$xauthority" xinput reattach "$id" "$target" >/dev/null 2>&1 || true
        DISPLAY="$display" XAUTHORITY="$xauthority" xinput enable "$id" >/dev/null 2>&1 || true
        [ -n "$target" ] && DISPLAY="$display" XAUTHORITY="$xauthority" xinput reattach "$id" "$target" >/dev/null 2>&1 || true
        ;;
      off)
        DISPLAY="$display" XAUTHORITY="$xauthority" xinput disable "$id" >/dev/null 2>&1 || true
        DISPLAY="$display" XAUTHORITY="$xauthority" xinput float "$id" >/dev/null 2>&1 || true
        ;;
    esac
  done <<EOF_IDS
$ids
EOF_IDS
}

session_verify_named_input_active() {
  local display="$1" xauthority="$2" name="$3" ids id found=0
  ids="$(session_xinput_ids_by_name "$display" "$xauthority" "$name")"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    found=1
    if ! session_xinput_device_enabled "$display" "$xauthority" "$id"; then
      printf 'input device is disabled on %s: %s id=%s\n' "$display" "$name" "$id" >&2
      return 1
    fi
    if ! session_xinput_device_attached "$display" "$xauthority" "$id"; then
      printf 'input device is not attached on %s: %s id=%s\n' "$display" "$name" "$id" >&2
      return 1
    fi
  done <<EOF_IDS
$ids
EOF_IDS
  if [ "$found" -eq 0 ]; then
    printf 'input device is missing on %s: %s\n' "$display" "$name" >&2
    return 1
  fi
}

session_route_input_for_display() {
  local display="$1" xauthority="$2" role="$3" verify="${4:-noverify}" pointer_master keyboard_master
  if ! command -v xinput >/dev/null 2>&1; then
    [ "$verify" = verify ] && return 1 || return 0
  fi
  pointer_master="$(session_xinput_master_id "$display" "$xauthority" pointer)"
  keyboard_master="$(session_xinput_master_id "$display" "$xauthority" keyboard)"
  if [ -z "$pointer_master" ] || [ -z "$keyboard_master" ]; then
    [ "$verify" = verify ] && return 1 || return 0
  fi

  case "$role" in
    spice)
      session_route_named_input "$display" "$xauthority" "QEMU USB Keyboard" "$keyboard_master" active
      session_route_named_input "$display" "$xauthority" "QEMU USB Tablet" "$pointer_master" active
      session_route_named_input "$display" "$xauthority" "spice vdagent tablet" "$pointer_master" active
      session_route_named_input "$display" "$xauthority" "QEMU USB Mouse" "" off
      if [ "$verify" = verify ]; then
        session_verify_named_input_active "$display" "$xauthority" "QEMU USB Keyboard"
        session_verify_named_input_active "$display" "$xauthority" "QEMU USB Tablet"
      fi
      ;;
    external)
      session_route_named_input "$display" "$xauthority" "QEMU USB Keyboard" "$keyboard_master" active
      session_route_named_input "$display" "$xauthority" "QEMU USB Mouse" "$pointer_master" active
      session_route_named_input "$display" "$xauthority" "QEMU USB Tablet" "" off
      session_route_named_input "$display" "$xauthority" "spice vdagent tablet" "" off
      if [ "$verify" = verify ]; then
        session_verify_named_input_active "$display" "$xauthority" "QEMU USB Keyboard"
        session_verify_named_input_active "$display" "$xauthority" "QEMU USB Mouse"
      fi
      ;;
    off)
      session_route_named_input "$display" "$xauthority" "QEMU USB Keyboard" "" off
      session_route_named_input "$display" "$xauthority" "QEMU USB Mouse" "" off
      session_route_named_input "$display" "$xauthority" "QEMU USB Tablet" "" off
      session_route_named_input "$display" "$xauthority" "spice vdagent tablet" "" off
      ;;
  esac
}

session_route_primary_input() {
  local role="$1" display xauthority dbus
  IFS=$'\t' read -r display xauthority dbus < <(primary_session_env || true)
  [ -n "${display:-}" ] && [ -n "${xauthority:-}" ] || return 0
  session_route_input_for_display "$display" "$xauthority" "$role" noverify
}

session_route_input() {
  local id="$1" role="$2" verify="${3:-noverify}" display xauthority
  session_load_env "$id" || return 0
  display="${DISPLAY_NAME:-}"
  xauthority="${XAUTHORITY_FILE:-}"
  [ -n "$display" ] && [ -n "$xauthority" ] || return 0
  session_route_input_for_display "$display" "$xauthority" "$role" "$verify"
}

write_session_xorg_config() {
  local path="$1" busid="$2"
  cat >"$path" <<CONF
Section "ServerFlags"
    Option "AutoAddGPU" "false"
    Option "AutoBindGPU" "false"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection

Section "Device"
    Identifier "vEGPU Native NVIDIA"
    Driver "nvidia"
    BusID "$busid"
    Option "AllowEmptyInitialConfiguration" "true"
    Option "PrimaryGPU" "true"
EndSection

Section "Screen"
    Identifier "vEGPU Native NVIDIA Screen"
    Device "vEGPU Native NVIDIA"
EndSection

Section "ServerLayout"
    Identifier "vEGPU Native NVIDIA Layout"
    Screen 0 "vEGPU Native NVIDIA Screen" 0 0
EndSection
CONF
}

session_wait_for_xorg() {
  local display="$1" xauthority="$2" i
  for i in $(seq 1 80); do
    if DISPLAY="$display" XAUTHORITY="$xauthority" xrandr --query >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

session_outputs_json_for_display() {
  local display="$1" xauthority="$2" raw
  raw="$(session_run_user "$display" "$xauthority" xrandr --query 2>/dev/null || true)"
  printf '%s' "$raw" | python3 -c '
import json, re, sys
outputs = []
for line in sys.stdin.read().splitlines():
    m = re.match(r"^(\S+)\s+(connected|disconnected)(?:\s+primary)?(?:\s+([0-9]+x[0-9]+)\+([0-9]+)\+([0-9]+))?", line)
    if not m:
        continue
    outputs.append({
        "name": m.group(1),
        "connected": m.group(2) == "connected",
        "primary": " primary " in f" {line} ",
        "mode": m.group(3) or "",
        "x": int(m.group(4) or 0),
        "y": int(m.group(5) or 0),
    })
print(json.dumps(outputs))
'
}

session_start() {
  local bdf idx name id display dir state_dir xauthority xorg_log desktop_log busid xorg_bin uid
  bdf="$(normalize_bdf "${1:?missing NVIDIA PCI bus id}")"
  validate_nvidia_bdf "$bdf"
  idx="${2:-$(session_index_for_bdf "$bdf" || true)}"
  [ -n "$idx" ] || idx=0
  name="$(session_name_for_bdf "$bdf")"
  id="$(session_id_for_bdf "$bdf")"
  display="$(session_display_for_index "$idx")"
  dir="$(session_dir_for_id "$id")"
  state_dir="$(session_state_dir_for_id "$id")"
  xauthority="$dir/xauthority"
  xorg_log="$dir/xorg.log"
  desktop_log="$dir/desktop.log"
  busid="$(xorg_bus_id_from_bdf "$bdf")"
  uid="$(id -u "$DISPLAY_USER" 2>/dev/null || true)"

  install -d -m 0755 "$SESSION_ROOT" "$SESSION_STATE_ROOT" "$dir" "$state_dir" "$dir/xorg.conf.d"
  write_session_xorg_config "$dir/xorg.conf" "$busid"
  if ! [ -f "$xauthority" ]; then
    xauth -f "$xauthority" add "$display" . "$(mcookie)" >/dev/null 2>&1 || true
    chown "$DISPLAY_USER:$DISPLAY_USER" "$xauthority" >/dev/null 2>&1 || true
  fi

  if ! session_xorg_running "$id"; then
    xorg_bin="$(command -v Xorg || printf '%s\n' /usr/lib/xorg/Xorg)"
    session_clear_stale_display_lock "$display"
    "$xorg_bin" "$display" -nolisten tcp -config "$dir/xorg.conf" -configdir "$dir/xorg.conf.d" -isolateDevice "$busid" -auth "$xauthority" -logfile "$xorg_log" -sharevts -novtswitch >"$dir/xorg.stdout.log" 2>&1 &
    printf '%s\n' "$!" >"$dir/xorg.pid"
  fi
  if ! session_wait_for_xorg "$display" "$xauthority"; then
    tail -80 "$xorg_log" >&2 || true
    return 1
  fi

  cat >"$(session_env_file_for_id "$id")" <<CONF
SESSION_ID=$id
GPU_BDF=$bdf
GPU_INDEX=$idx
GPU_NAME=$(printf '%q' "$name")
DISPLAY_NAME=$display
XAUTHORITY_FILE=$xauthority
CONF

  if ! session_pid_alive "$dir/desktop.pid"; then
    runuser -u "$DISPLAY_USER" -- env \
      DISPLAY="$display" \
      XAUTHORITY="$xauthority" \
      HOME="/home/$DISPLAY_USER" \
      USER="$DISPLAY_USER" \
      LOGNAME="$DISPLAY_USER" \
      XDG_SESSION_TYPE=x11 \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      dbus-run-session -- sh -lc 'xfce4-session' >"$desktop_log" 2>&1 &
    printf '%s\n' "$!" >"$dir/desktop.pid"
  fi
  session_route_input "$id" off
  (
    sleep 2
    session_run_user "$display" "$xauthority" "$CUSTOMIZATION_SCRIPT" apply-session >/dev/null 2>&1 || true
  ) &
}

session_stop() {
  local id="$1" dir
  dir="$(session_dir_for_id "$id")"
  if session_pid_alive "$dir/desktop.pid"; then
    kill "$(cat "$dir/desktop.pid")" >/dev/null 2>&1 || true
  fi
  if session_pid_alive "$dir/xorg.pid"; then
    kill "$(cat "$dir/xorg.pid")" >/dev/null 2>&1 || true
  fi
  rm -rf "$dir" "$(session_state_dir_for_id "$id")"
  if [ "$(cat "$SESSION_ROOT/active" 2>/dev/null || true)" = "$id" ]; then
    printf '%s\n' macos >"$SESSION_ROOT/active"
    session_route_primary_input spice
  fi
}

session_enter() {
  local id="$1" other env_file
  install -d -m 0755 "$SESSION_ROOT"
  session_load_env "$id"
  session_route_input "$id" external verify
  session_route_primary_input off
  for env_file in "$SESSION_STATE_ROOT"/*/session.env; do
    [ -f "$env_file" ] || continue
    # shellcheck disable=SC1090
    . "$env_file"
    other="${SESSION_ID:-}"
    [ -n "$other" ] || continue
    if [ "$other" != "$id" ]; then
      session_route_input "$other" off
    fi
  done
  printf '%s\n' "$id" >"$SESSION_ROOT/active"
}

session_release() {
  local env_file id
  install -d -m 0755 "$SESSION_ROOT"
  for env_file in "$SESSION_STATE_ROOT"/*/session.env; do
    [ -f "$env_file" ] || continue
    # shellcheck disable=SC1090
    . "$env_file"
    id="${SESSION_ID:-}"
    [ -n "$id" ] || continue
    session_route_input "$id" off
  done
  session_route_primary_input spice
  printf '%s\n' macos >"$SESSION_ROOT/active"
}

session_outputs_json() {
  local id="$1" display xauthority
  if ! session_load_env "$id" || ! session_xorg_running "$id"; then
    printf '{"id":%s,"outputs":[]}\n' "$(printf '%s' "$id" | json_value)"
    return 0
  fi
  display="$DISPLAY_NAME"
  xauthority="$XAUTHORITY_FILE"
  printf '{"id":%s,"outputs":' "$(printf '%s' "$id" | json_value)"
  session_outputs_json_for_display "$display" "$xauthority"
  printf '}\n'
}

session_rescan_displays() {
  local id="$1" display xauthority
  session_load_env "$id" || {
    printf 'No display session state for %s\n' "$id" >&2
    return 1
  }
  session_xorg_running "$id" || {
    printf 'Display session is not running: %s\n' "$id" >&2
    return 1
  }
  display="$DISPLAY_NAME"
  xauthority="$XAUTHORITY_FILE"
  session_wait_for_xorg "$display" "$xauthority"
  session_run_user "$display" "$xauthority" "$CUSTOMIZATION_SCRIPT" apply-display
}

session_restart() {
  local id="$1" bdf idx was_active=0
  session_load_env "$id" || {
    printf 'No display session state for %s\n' "$id" >&2
    return 1
  }
  bdf="${GPU_BDF:?missing session GPU_BDF}"
  idx="${GPU_INDEX:-}"
  if [ "$(cat "$SESSION_ROOT/active" 2>/dev/null || true)" = "$id" ]; then
    was_active=1
  fi
  session_stop "$id"
  session_start "$bdf" "$idx"
  if [ "$was_active" -eq 1 ]; then
    session_enter "$id"
  fi
}

sessions_json_append_entry() {
  local out_file="$1" first_file="$2" active="$3" idx="$4" name="$5" bdf="$6" id="$7" display="$8" valid="$9" running="${10}" outputs="${11}" first
  first="$(cat "$first_file" 2>/dev/null || printf 1)"
  [ "$first" -eq 1 ] || printf ',' >>"$out_file"
  printf 0 >"$first_file"
  printf '{"id":%s,"index":%s,"name":%s,"bdf":%s,"display":%s,"state":%s,"active":%s,"valid":%s,"outputs":%s}' \
    "$(printf '%s' "$id" | json_value)" \
    "$(printf '%s' "$idx" | json_value)" \
    "$(printf '%s' "$name" | json_value)" \
    "$(printf '%s' "$bdf" | json_value)" \
    "$(printf '%s' "$display" | json_value)" \
    "$(printf '%s' "$([ "$running" = true ] && printf running || printf stopped)" | json_value)" \
    "$([ "$active" = "$id" ] && printf true || printf false)" \
    "$valid" \
    "$outputs" >>"$out_file"
}

sessions_json() {
  local active entry_active idx name raw_bdf bdf valid id display running outputs env_file emitted_active=0 entries first_file
  declare -A seen_sessions=()
  install -d -m 0755 "$SESSION_ROOT" "$SESSION_STATE_ROOT"
  active="$(cat "$SESSION_ROOT/active" 2>/dev/null || printf '%s' macos)"
  entries="$(mktemp)"
  first_file="$(mktemp)"
  printf 1 >"$first_file"
  while IFS=$'\t' read -r idx name raw_bdf; do
    [ -n "${raw_bdf:-}" ] || continue
    bdf="$(normalize_bdf "$raw_bdf" 2>/dev/null || printf '%s' "$raw_bdf")"
    valid=false
    gpu_valid_for_bdf "$bdf" && valid=true
    id="$(session_id_for_bdf "$bdf")"
    display="$(session_display_for_index "$idx")"
    running=false
    session_xorg_running "$id" && running=true
    [ "$running" = true ] && valid=true
    outputs='[]'
    if [ "$running" = true ] && session_load_env "$id"; then
      outputs="$(session_outputs_json_for_display "$DISPLAY_NAME" "$XAUTHORITY_FILE")"
    fi
    entry_active="$active"
    if [ "$active" = "$id" ] && [ "$running" != true ]; then
      entry_active=macos
    fi
    [ "$active" = "$id" ] && [ "$running" = true ] && [ "$valid" = true ] && emitted_active=1
    seen_sessions["$id"]=1
    sessions_json_append_entry "$entries" "$first_file" "$entry_active" "$idx" "$name" "$bdf" "$id" "$display" "$valid" "$running" "$outputs"
  done < <(gpu_rows || true)
  for env_file in "$SESSION_STATE_ROOT"/*/session.env; do
    [ -f "$env_file" ] || continue
    SESSION_ID= GPU_BDF= GPU_INDEX= GPU_NAME= DISPLAY_NAME= XAUTHORITY_FILE=
    # shellcheck disable=SC1090
    . "$env_file"
    id="${SESSION_ID:-}"
    [ -n "$id" ] || continue
    [ -z "${seen_sessions[$id]+x}" ] || continue
    bdf="${GPU_BDF:-}"
    idx="${GPU_INDEX:-0}"
    name="${GPU_NAME:-NVIDIA GPU}"
    display="${DISPLAY_NAME:-$(session_display_for_index "$idx")}"
    valid=false
    [ -n "$bdf" ] && gpu_valid_for_bdf "$bdf" && valid=true
    running=false
    session_xorg_running "$id" && running=true
    [ "$running" = true ] && valid=true
    outputs='[]'
    if [ "$running" = true ] && [ -n "${DISPLAY_NAME:-}" ] && [ -n "${XAUTHORITY_FILE:-}" ]; then
      outputs="$(session_outputs_json_for_display "$DISPLAY_NAME" "$XAUTHORITY_FILE")"
    fi
    entry_active="$active"
    if [ "$active" = "$id" ] && [ "$running" != true ]; then
      entry_active=macos
    fi
    [ "$active" = "$id" ] && [ "$running" = true ] && [ "$valid" = true ] && emitted_active=1
    sessions_json_append_entry "$entries" "$first_file" "$entry_active" "$idx" "$name" "$bdf" "$id" "$display" "$valid" "$running" "$outputs"
  done
  if [ "$active" != macos ] && [ "$emitted_active" -eq 0 ]; then
    active=macos
    printf '%s\n' macos >"$SESSION_ROOT/active"
  fi
  printf '{"active":%s,"sessions":[' "$(printf '%s' "$active" | json_value)"
  cat "$entries"
  printf ']}\n'
  rm -f "$entries" "$first_file"
}

case "${1:-status}" in
  install-global-defaults)
    run_customization install-system
    ;;
  boot-spice)
    configure_spice_without_restart
    write_mode_file <<CONF
VEGPU_DISPLAY_MODE=spice
CONF
    ;;
  configure-current)
    configure_current_without_restart
    ;;
  spice)
    configure_spice_without_restart
    write_mode_file <<CONF
VEGPU_DISPLAY_MODE=spice
CONF
    session_release || true
    restart_lightdm
    ;;
  external-primary)
    nvidia_bdf="$(normalize_bdf "${2:?missing NVIDIA PCI bus id}")"
    nvidia_index="${3:-}"
    configure_external_without_restart "$nvidia_bdf"
    write_mode_file <<CONF
VEGPU_DISPLAY_MODE=external-primary
VEGPU_NVIDIA_BDF=$nvidia_bdf
VEGPU_NVIDIA_INDEX=$nvidia_index
CONF
    restart_lightdm
    ;;
  reload)
    configure_current_without_restart
    restart_lightdm
    ;;
  status)
    if [ -f "$MODE_FILE" ]; then
      cat "$MODE_FILE"
    else
      printf '%s\n' "VEGPU_DISPLAY_MODE=spice"
    fi
    ;;
  sessions)
    [ "${2:-}" = "--json" ] || {
      printf 'usage: %s sessions --json\n' "$0" >&2
      exit 2
    }
    sessions_json
    ;;
  session-start)
    session_start "${2:?missing NVIDIA PCI bus id}" "${3:-}"
    ;;
  session-enter|session-activate)
    session_enter "${2:?missing session id}"
    ;;
  session-release)
    session_release
    ;;
  session-stop)
    session_stop "${2:?missing session id}"
    ;;
  session-outputs)
    session_outputs_json "${2:?missing session id}"
    ;;
  session-rescan)
    session_rescan_displays "${2:?missing session id}"
    ;;
  session-restart)
    session_restart "${2:?missing session id}"
    ;;
  *)
    printf 'usage: %s {install-global-defaults|boot-spice|configure-current|spice|external-primary <pci-bdf> [index]|reload|status|sessions --json|session-start <bdf> [index]|session-enter <id>|session-release|session-stop <id>|session-outputs <id>|session-rescan <id>|session-restart <id>}\n' "$0" >&2
    exit 2
    ;;
esac
HELPER_SCRIPT
  install_file_if_changed "$tmp" "$DISPLAY_HELPER" 0755
  rm -f "$tmp"

  tmp="$(mktemp)"
  cat >"$tmp" <<'CONTROL_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

MODE_FILE=/etc/vegpu/display-mode.conf
CUSTOMIZATION_SCRIPT=/usr/local/libexec/vegpu/customization.sh

json_value() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

discover_session_env() {
  local target_xauthority pid envlines display xauthority dbus
  target_xauthority="${XAUTHORITY:-}"
  for pid in $(pgrep -u "$(id -u)" xfce4-session 2>/dev/null || true) \
             $(pgrep -u "$(id -u)" xfce4-panel 2>/dev/null || true) \
             $(pgrep -u "$(id -u)" xfdesktop 2>/dev/null || true); do
    [ -r "/proc/$pid/environ" ] || continue
    envlines="$(tr '\0' '\n' <"/proc/$pid/environ")"
    display="$(printf '%s\n' "$envlines" | awk -F= '$1 == "DISPLAY" { print substr($0, index($0, "=") + 1); exit }')"
    [ -n "$display" ] || continue
    xauthority="$(printf '%s\n' "$envlines" | awk -F= '$1 == "XAUTHORITY" { print substr($0, index($0, "=") + 1); exit }')"
    if [ -n "$target_xauthority" ] && [ -n "$xauthority" ] && [ "$xauthority" != "$target_xauthority" ]; then
      continue
    fi
    dbus="$(printf '%s\n' "$envlines" | awk -F= '$1 == "DBUS_SESSION_BUS_ADDRESS" { print substr($0, index($0, "=") + 1); exit }')"
    export DISPLAY="$display"
    [ -n "$xauthority" ] && export XAUTHORITY="$xauthority"
    [ -n "$dbus" ] && export DBUS_SESSION_BUS_ADDRESS="$dbus"
    return 0
  done
  return 1
}

session_env() {
  local uid bus
  if [ -z "${DISPLAY:-}" ]; then
    discover_session_env || return 1
  fi
  uid="$(id -u)"
  bus="/run/user/$uid/bus"
  export DISPLAY
  export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
  if [ -S "$bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$bus}"
  fi
}

mode_value() {
  local key="$1"
  [ -f "$MODE_FILE" ] || return 0
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$MODE_FILE"
}

normalize_bdf() {
  local raw="$1" domain bus slot func
  raw="${raw#pci:}"
  raw="${raw,,}"
  IFS=':.' read -r domain bus slot func <<BDF_EOF
$raw
BDF_EOF
  domain="${domain:-0000}"
  bus="${bus:-00}"
  slot="${slot:-00}"
  func="${func:-0}"
  domain="${domain: -4}"
  printf '%04x:%02x:%02x.%d\n' "$((16#$domain))" "$((16#$bus))" "$((16#$slot))" "$((10#$func))"
}

gpu_rows() {
  nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv,noheader,nounits 2>/dev/null |
    awk -F', *' 'NF >= 3 { printf "%s\t%s\t%s\n", $1, $2, $3 }'
}

gpu_valid_for_bdf() {
  local bdf="$1"
  [ -e "/sys/bus/pci/devices/$bdf/vendor" ] || return 1
  [ "$(cat "/sys/bus/pci/devices/$bdf/vendor" 2>/dev/null || true)" = "0x10de" ]
}

list_gpus_json() {
  local first=1 idx name raw_bdf bdf valid
  printf '{"gpus":['
  while IFS=$'\t' read -r idx name raw_bdf; do
    [ -n "${raw_bdf:-}" ] || continue
    bdf="$(normalize_bdf "$raw_bdf" 2>/dev/null || printf '%s' "$raw_bdf")"
    valid=false
    gpu_valid_for_bdf "$bdf" && valid=true
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"index":%s,"name":%s,"bdf":%s,"valid":%s}' \
      "$(printf '%s' "$idx" | json_value)" \
      "$(printf '%s' "$name" | json_value)" \
      "$(printf '%s' "$bdf" | json_value)" \
      "$valid"
  done < <(gpu_rows || true)
  printf ']}\n'
}

selected_gpu_from_mode_json() {
  local selected_bdf="$1" selected_index="$2" idx name raw_bdf bdf
  [ -n "$selected_bdf" ] || {
    printf 'null'
    return 0
  }
  while IFS=$'\t' read -r idx name raw_bdf; do
    bdf="$(normalize_bdf "$raw_bdf" 2>/dev/null || printf '%s' "$raw_bdf")"
    if [ "$bdf" = "$selected_bdf" ]; then
      [ -n "$selected_index" ] || selected_index="$idx"
      printf '{"index":%s,"name":%s,"bdf":%s}' \
        "$(printf '%s' "$selected_index" | json_value)" \
        "$(printf '%s' "$name" | json_value)" \
        "$(printf '%s' "$selected_bdf" | json_value)"
      return 0
    fi
  done < <(gpu_rows || true)
  printf '{"index":%s,"name":%s,"bdf":%s}' \
    "$(printf '%s' "$selected_index" | json_value)" \
    "$(printf '%s' "NVIDIA GPU" | json_value)" \
    "$(printf '%s' "$selected_bdf" | json_value)"
}

status_json() {
  local mode selected_bdf selected_index display_manager_active session_active
  mode="$(mode_value VEGPU_DISPLAY_MODE)"
  [ -n "$mode" ] || mode=spice
  selected_bdf="$(mode_value VEGPU_NVIDIA_BDF)"
  if [ -n "$selected_bdf" ]; then
    selected_bdf="$(normalize_bdf "$selected_bdf" 2>/dev/null || printf '%s' "$selected_bdf")"
  fi
  selected_index="$(mode_value VEGPU_NVIDIA_INDEX)"
  display_manager_active=false
  session_active=false
  systemctl is-active --quiet lightdm >/dev/null 2>&1 && display_manager_active=true
  pgrep -x Xorg >/dev/null 2>&1 && session_active=true
  printf '{"mode":%s,"selectedGPU":' "$(printf '%s' "$mode" | json_value)"
  selected_gpu_from_mode_json "$selected_bdf" "$selected_index"
  printf ',"displayManagerActive":%s,"sessionActive":%s,"lightdmActive":%s,"xorgActive":%s}\n' \
    "$display_manager_active" "$session_active" "$display_manager_active" "$session_active"
}

switch_external_primary() {
  local bdf idx
  bdf="$(normalize_bdf "${1:?missing NVIDIA PCI bus id}")"
  idx="${2:-}"
  sudo -n /usr/local/sbin/vegpu-display-mode-helper external-primary "$bdf" "$idx"
}

switch_spice() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper spice
}

reload_display() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper reload
}

sessions_json() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper sessions --json
}

session_start() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper session-start "${1:?missing NVIDIA PCI bus id}" "${2:-}"
}

session_enter() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper session-enter "${1:?missing session id}"
}

session_release() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper session-release
}

session_stop() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper session-stop "${1:?missing session id}"
}

session_outputs() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper session-outputs "${1:?missing session id}"
}

session_rescan() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper session-rescan "${1:?missing session id}"
}

session_restart() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper session-restart "${1:?missing session id}"
}

apply_display() {
  [ -x "$CUSTOMIZATION_SCRIPT" ] || {
    printf 'Missing vEGPU GUI customization script: %s\n' "$CUSTOMIZATION_SCRIPT" >&2
    return 1
  }
  session_env
  "$CUSTOMIZATION_SCRIPT" apply-display
}

case "${1:-status}" in
  --apply-primary-display|apply-display)
    apply_display
    ;;
  status)
    if [ "${2:-}" = "--json" ]; then
      status_json
    else
      sudo -n /usr/local/sbin/vegpu-display-mode-helper status
    fi
    ;;
  list-gpus)
    if [ "${2:-}" = "--json" ]; then
      list_gpus_json
    else
      printf 'usage: %s list-gpus --json\n' "$0" >&2
      exit 2
    fi
    ;;
  external-primary)
    switch_external_primary "${2:?missing NVIDIA PCI bus id}" "${3:-}"
    ;;
  spice)
    switch_spice
    ;;
  reload)
    reload_display
    ;;
  sessions)
    if [ "${2:-}" = "--json" ]; then
      sessions_json
    else
      printf 'usage: %s sessions --json\n' "$0" >&2
      exit 2
    fi
    ;;
  session-start)
    session_start "${2:?missing NVIDIA PCI bus id}" "${3:-}"
    ;;
  session-enter|session-activate)
    session_enter "${2:?missing session id}"
    ;;
  session-release)
    session_release
    ;;
  session-stop)
    session_stop "${2:?missing session id}"
    ;;
  session-outputs)
    session_outputs "${2:?missing session id}"
    ;;
  session-rescan)
    session_rescan "${2:?missing session id}"
    ;;
  session-restart)
    session_restart "${2:?missing session id}"
    ;;
  *)
    printf 'usage: %s {status [--json]|list-gpus --json|external-primary <pci-bdf> [index]|spice|reload|sessions --json|session-start <bdf> [index]|session-enter <id>|session-release|session-stop <id>|session-outputs <id>|session-rescan <id>|session-restart <id>|--apply-primary-display}\n' "$0" >&2
    exit 2
    ;;
esac
CONTROL_SCRIPT
  install_file_if_changed "$tmp" "$DISPLAY_CONTROL" 0755
  rm -f "$tmp"

  printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/vegpu-display-mode-helper *\n' "$HUMAN_USER" >/etc/sudoers.d/90-vegpu-display-control
  chmod 0440 /etc/sudoers.d/90-vegpu-display-control
  visudo -cf /etc/sudoers.d/90-vegpu-display-control >/dev/null 2>&1 || rm -f /etc/sudoers.d/90-vegpu-display-control

  cat >/etc/systemd/system/vegpu-display-boot-reset.service <<'EOF'
[Unit]
Description=Reset vEGPU display mode to SPICE before the graphical login
After=local-fs.target
Before=display-manager.service lightdm.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vegpu-display-mode-helper boot-spice

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable vegpu-display-boot-reset.service >/dev/null 2>&1 || true

  find "/home/$HUMAN_USER/.config/autostart" -maxdepth 1 -type f -name 'vegpu-display-*.desktop' -delete 2>/dev/null || true
}

configure_launch_display() {
  if [ "${VEGPU_FORCE_SPICE_ON_LAUNCH:-0}" = "1" ]; then
    case "$("$DISPLAY_HELPER" status 2>/dev/null | awk -F= '$1 == "VEGPU_DISPLAY_MODE" { print $2; exit }')" in
      external-primary)
        "$DISPLAY_HELPER" configure-current
        return 0
        ;;
    esac
    "$DISPLAY_HELPER" boot-spice
    return 0
  fi
  "$DISPLAY_HELPER" configure-current
}

enable_runtime_services() {
  systemctl enable ssh qemu-guest-agent lightdm >/dev/null 2>&1 || true
  systemctl enable spice-vdagentd >/dev/null 2>&1 || systemctl enable spice-vdagent >/dev/null 2>&1 || true
  systemctl is-active --quiet ssh >/dev/null 2>&1 || systemctl start ssh >/dev/null 2>&1 || true
  systemctl is-active --quiet qemu-guest-agent >/dev/null 2>&1 || systemctl start qemu-guest-agent >/dev/null 2>&1 || true
  systemctl is-active --quiet lightdm >/dev/null 2>&1 || systemctl start lightdm >/dev/null 2>&1 || true
  systemctl is-active --quiet spice-vdagentd >/dev/null 2>&1 || systemctl start spice-vdagentd >/dev/null 2>&1 || true
}

install_display_control_only() {
  install_customization_script
  run_customization write-prefs
  install_display_control
}

install_full_gui() {
  install -d "$STATE_DIR"
  install_desktop_stack
  configure_desktop_network
  repair_share_access
  repair_desktop_links
  install_lightdm_autologin
  install_spice_agent_autostart
  install_customization_script
  install_appearance_once
  install_display_control
  configure_launch_display
  enable_runtime_services
}

case "${1:-}" in
  --install-display-control-only)
    install_display_control_only
    ;;
  ""|--install)
    install_full_gui
    ;;
  *)
    printf 'usage: %s [--install|--install-display-control-only]\n' "$0" >&2
    exit 2
    ;;
esac

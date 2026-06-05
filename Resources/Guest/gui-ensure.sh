#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

STATE_DIR=/var/lib/vegpu
MARKER="$STATE_DIR/gui-ready"
SHARE=/mnt/vegpu-share
HUMAN_USER=vegpu
XORG_CHANGED=0
CUSTOMIZATION_SCRIPT=/usr/local/libexec/vegpu/customization.sh
SCALING_APP_DIR=/usr/local/libexec/vegpu/scaling-app

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
      printf '[gui-ensure] apt lock busy; waiting for current package operation (%s/120)\n' "$attempt" >&2
      sleep 5
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$code"
  done
  printf '%s\n' "$output" >&2
  return "$code"
}

mkdir -p "$STATE_DIR"

install_customization_script() {
  local script_dir source_path
  install -d "$(dirname "$CUSTOMIZATION_SCRIPT")"
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  source_path="${VEGPU_CUSTOMIZATION_SOURCE:-$script_dir/customization.sh}"
  if [ -f "$source_path" ]; then
    install -m 0755 "$source_path" "$CUSTOMIZATION_SCRIPT"
    return 0
  fi
  if [ -f "$CUSTOMIZATION_SCRIPT" ]; then
    return 0
  fi
  printf 'Missing vEGPU GUI customization script: %s\n' "$source_path" >&2
  exit 1
}

run_customization() {
  "$CUSTOMIZATION_SCRIPT" "$@"
}

install_scaling_app() {
  local script_dir source_dir package dir candidate
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  source_dir="${VEGPU_SCALING_APP_SOURCE:-$script_dir/scaling-app}"
  package=""
  for dir in /var/lib/vegpu/packages "$source_dir/package" "$SCALING_APP_DIR/package"; do
    [ -d "$dir" ] || continue
    candidate="$(find "$dir" -maxdepth 1 -type f -name 'vegpu-scaling_*.deb' 2>/dev/null | sort | tail -n 1 || true)"
    [ -n "$candidate" ] || continue
    package="$candidate"
  done
  if [ -n "$package" ] && [ -f "$package" ]; then
    if ! dpkg -i "$package" >/dev/null 2>&1; then
      apt_get install -y -f >/dev/null 2>&1 || true
      dpkg -i "$package" >/dev/null 2>&1 || true
    fi
    return 0
  fi
  if [ -f "$source_dir/install.sh" ]; then
    rm -rf "$SCALING_APP_DIR"
    install -d "$SCALING_APP_DIR"
    cp -a "$source_dir"/. "$SCALING_APP_DIR"/
  fi
  if [ -x "$SCALING_APP_DIR/install.sh" ]; then
    VEGPU_SCALING_SKIP_DEPS=1 "$SCALING_APP_DIR/install.sh" >/dev/null 2>&1 || true
  fi
}

repair_share_access() {
  usermod -aG dialout "$HUMAN_USER" 2>/dev/null || true
  usermod -aG dialout vegpuctl 2>/dev/null || true
}

install_desktop_mount_policy() {
  install -d /etc/polkit-1/rules.d
  cat >/etc/polkit-1/rules.d/49-vegpu-desktop-mount.rules <<'EOS'
polkit.addRule(function(action, subject) {
  if (subject.user !== "vegpu") {
    return;
  }
  var allowed = [
    "org.freedesktop.udisks2.filesystem-mount",
    "org.freedesktop.udisks2.filesystem-mount-system",
    "org.freedesktop.udisks2.filesystem-unmount-others",
    "org.freedesktop.udisks2.eject-media",
    "org.freedesktop.udisks2.power-off-drive"
  ];
  if (allowed.indexOf(action.id) >= 0) {
    return polkit.Result.YES;
  }
});
EOS
  chmod 0644 /etc/polkit-1/rules.d/49-vegpu-desktop-mount.rules
  /usr/bin/timeout 5s systemctl try-restart polkit >/dev/null 2>&1 || true
}

firefox_available() {
  command -v firefox >/dev/null 2>&1 || command -v firefox-esr >/dev/null 2>&1
}

install_desktop_stack() {
  if [ -f "$MARKER" ] &&
     command -v startxfce4 >/dev/null 2>&1 &&
     command -v spice-vdagent >/dev/null 2>&1 &&
     command -v thunar >/dev/null 2>&1 &&
     firefox_available &&
     python3 -c 'import gi' >/dev/null 2>&1; then
    return 0
  fi
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
    firefox-esr \
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
}

configure_desktop_network() {
  command -v nmcli >/dev/null 2>&1 || return 0

  install -d /etc/NetworkManager/conf.d /etc/NetworkManager/system-connections
  cat >/etc/NetworkManager/conf.d/90-vegpu-managed.conf <<'EOF'
[ifupdown]
managed=true

[keyfile]
unmanaged-devices=none
EOF
  cat >/etc/NetworkManager/system-connections/vegpu-vmnet.nmconnection <<'EOF'
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
  chmod 0600 /etc/NetworkManager/system-connections/vegpu-vmnet.nmconnection
  systemctl enable NetworkManager >/dev/null 2>&1 || true
  systemctl restart NetworkManager >/dev/null 2>&1 || true
  nmcli connection reload >/dev/null 2>&1 || true
  nmcli device set enp0s3 managed yes >/dev/null 2>&1 || true
  nmcli connection up "vEGPU vmnet" ifname enp0s3 >/dev/null 2>&1 || true
}

remove_managed_mac_share_path() {
  local path="$1"
  if [ -L "$path" ] || [ -f "$path" ]; then
    rm -f "$path"
  elif [ -d "$path" ]; then
    rmdir "$path" 2>/dev/null || true
  fi
}

run_user_command() {
  local user="$1"
  shift
  local home uid bus
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  home="${home:-/home/$user}"
  uid="$(id -u "$user" 2>/dev/null || true)"
  bus="/run/user/$uid/bus"
  if command -v runuser >/dev/null 2>&1; then
    if [ -n "$uid" ] && [ -S "$bus" ]; then
      runuser -u "$user" -- env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" "$@"
    elif command -v dbus-run-session >/dev/null 2>&1; then
      runuser -u "$user" -- env HOME="$home" dbus-run-session "$@"
    else
      runuser -u "$user" -- env HOME="$home" "$@"
    fi
  elif command -v sudo >/dev/null 2>&1; then
    if [ -n "$uid" ] && [ -S "$bus" ]; then
      sudo -u "$user" env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" "$@"
    else
      sudo -u "$user" env HOME="$home" "$@"
    fi
  else
    return 1
  fi
}

trust_desktop_file() {
  local user="$1"
  local file="$2"
  local home checksum
  [ -f "$file" ] || return 0
  chmod 0755 "$file" >/dev/null 2>&1 || true
  chown "$user:$user" "$file" >/dev/null 2>&1 || true
  command -v gio >/dev/null 2>&1 || return 0
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  if [ -n "$home" ]; then
    install -d -o "$user" -g "$user" "$home/.local/share/gvfs-metadata"
    chown "$user:$user" "$home/.local" "$home/.local/share" >/dev/null 2>&1 || true
  fi
  run_user_command "$user" gio set "$file" metadata::trusted true >/dev/null 2>&1 || true
  command -v sha256sum >/dev/null 2>&1 || return 0
  checksum="$(sha256sum "$file" | awk '{ print $1 }')"
  [ -n "$checksum" ] || return 0
  run_user_command "$user" gio set -t string "$file" metadata::xfce-exe-checksum "$checksum" >/dev/null 2>&1 || true
}

prune_mac_share_bookmarks() {
  local bookmarks="$1"
  local tmp
  [ -f "$bookmarks" ] || return 0
  tmp="$(mktemp)"
  awk '
    index($0, "file:///mnt/vegpu-share") == 0 &&
    index($0, "file:///home/vegpu/Mac Share") == 0 &&
    index($0, "file:///home/vegpu/Mac%20Share") == 0 &&
    index($0, "file:///home/vegpu/Desktop/Mac Share") == 0 &&
    index($0, "file:///home/vegpu/Desktop/Mac%20Share") == 0 {
      print
    }
  ' "$bookmarks" >"$tmp"
  install -o "$HUMAN_USER" -g "$HUMAN_USER" -m 0644 "$tmp" "$bookmarks"
  rm -f "$tmp"
}

install_mac_share_recover_helper() {
  install -d /usr/local/sbin /etc/sudoers.d
  cat >/usr/local/sbin/vegpu-mac-share-recover <<'EOS'
#!/usr/bin/env bash
set -u

SHARE="${1:-/mnt/vegpu-share}"
HOST="${2:-172.29.253.1}"
POLICY=/etc/vegpu/mac-share-policy
EXPECTED=""

if [ -r "$POLICY" ]; then
  . "$POLICY"
  SHARE="${VEGPU_MAC_SHARE_TARGET:-$SHARE}"
  HOST="${VEGPU_MAC_SHARE_HOST:-$HOST}"
  EXPECTED="${VEGPU_MAC_SHARE_SOURCE:-}"
fi

case "$SHARE" in
  /mnt/vegpu-share|/mnt/vegpu-share/) ;;
  *) exit 2 ;;
esac

mountinfo_line() {
  awk -v target="$SHARE" '$5 == target {
    for (i = 1; i <= NF; i++) {
      if ($i == "-") {
        print $(i + 1) "\t" $(i + 2)
        exit
      }
    }
  }' /proc/self/mountinfo 2>/dev/null || true
}

nfs_rpc_ready() {
  local host="${1:-$HOST}"
  if command -v rpcinfo >/dev/null 2>&1; then
    timeout 3s rpcinfo -t "$host" nfs 3 >/dev/null 2>&1
    return $?
  fi
  if command -v nc >/dev/null 2>&1; then
    timeout 3s nc -z "$host" 2049 >/dev/null 2>&1
    return $?
  fi
  timeout 3s bash -c ':</dev/tcp/"$1"/2049' bash "$host" >/dev/null 2>&1
}

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/vegpu-mac-share-recover.lock
  flock -n 9 || exit 0
fi

mount_unit="$(systemd-escape --path --suffix=mount "$SHARE" 2>/dev/null || true)"
line="$(mountinfo_line)"
current_fstype="$(printf '%s' "$line" | cut -f1)"
current_source="$(printf '%s' "$line" | cut -f2)"
if { [ "$current_fstype" = "nfs" ] || [ "$current_fstype" = "nfs4" ]; } &&
   [ -n "$EXPECTED" ] &&
   [ "$current_source" != "$EXPECTED" ]; then
  umount_cmd="$(command -v umount 2>/dev/null || true)"
  if [ -n "$umount_cmd" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout 3s "$umount_cmd" -l "$SHARE" >/dev/null 2>&1 || true
    else
      "$umount_cmd" -l "$SHARE" >/dev/null 2>&1 || true
    fi
  fi
elif [ "$current_fstype" = "nfs" ] || [ "$current_fstype" = "nfs4" ]; then
  nfs_rpc_ready "$HOST" || exit 0
fi

if command -v systemctl >/dev/null 2>&1 && [ -n "$mount_unit" ]; then
  systemctl reset-failed "$mount_unit" >/dev/null 2>&1 || true
  nfs_rpc_ready "$HOST" || exit 0
  systemctl start --no-block "$mount_unit" >/dev/null 2>&1 ||
    systemctl start "$mount_unit" >/dev/null 2>&1 || true
fi
EOS
  chmod 0755 /usr/local/sbin/vegpu-mac-share-recover

  cat >/etc/sudoers.d/90-vegpu-mac-share-launcher <<'EOS'
vegpu ALL=(root) NOPASSWD: /usr/local/sbin/vegpu-mac-share-recover
EOS
  chmod 0440 /etc/sudoers.d/90-vegpu-mac-share-launcher
  if command -v visudo >/dev/null 2>&1; then
    visudo -cf /etc/sudoers.d/90-vegpu-mac-share-launcher >/dev/null 2>&1 ||
      rm -f /etc/sudoers.d/90-vegpu-mac-share-launcher
  fi
}

install_mac_share_launcher() {
  install -d /usr/local/bin /usr/local/libexec/vegpu
  install_mac_share_recover_helper

  cat >/usr/local/libexec/vegpu/vegpu-open-mac-share-worker <<'EOS'
#!/usr/bin/env bash
set -u

SHARE="${1:-/mnt/vegpu-share}"
RECOVER=/usr/local/sbin/vegpu-mac-share-recover
HOST="${VEGPU_MAC_SHARE_HOST:-172.29.253.1}"

notify_user() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "vEGPU" "$1" 2>/dev/null || true
  else
    printf '%s\n' "$1" >&2
  fi
}

mountinfo_type() {
  awk -v target="$SHARE" '$5 == target {
    for (i = 1; i <= NF; i++) {
      if ($i == "-") {
        print $(i + 1)
        exit
      }
    }
  }' /proc/self/mountinfo 2>/dev/null || true
}

nfs_source_host() {
  awk -v target="$SHARE" '$5 == target {
    for (i = 1; i <= NF; i++) {
      if ($i == "-") {
        split($(i + 2), parts, ":")
        print parts[1]
        exit
      }
    }
  }' /proc/self/mountinfo 2>/dev/null || true
}

nfs_rpc_ready() {
  local host="${1:-$HOST}"
  if command -v rpcinfo >/dev/null 2>&1; then
    timeout 3s rpcinfo -t "$host" nfs 3 >/dev/null 2>&1
    return $?
  fi
  if command -v nc >/dev/null 2>&1; then
    timeout 3s nc -z "$host" 2049 >/dev/null 2>&1
    return $?
  fi
  timeout 3s bash -c ':</dev/tcp/"$1"/2049' bash "$host" >/dev/null 2>&1
}

share_ready() {
  local fstype host
  fstype="$(mountinfo_type)"
  [ "$fstype" = "nfs" ] || [ "$fstype" = "nfs4" ] || return 1
  host="$(nfs_source_host)"
  [ -n "$host" ] || host="$HOST"
  nfs_rpc_ready "$host"
}

launch_detached() {
  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$@" >/dev/null 2>&1 </dev/null || true
  elif command -v nohup >/dev/null 2>&1; then
    nohup "$@" >/dev/null 2>&1 </dev/null &
  else
    "$@" >/dev/null 2>&1 </dev/null &
  fi
}

schedule_recover() {
  [ -x "$RECOVER" ] || return 0
  command -v sudo >/dev/null 2>&1 || return 0
  launch_detached sudo -n "$RECOVER" "$SHARE" "$HOST"
}

open_file_manager() {
  if command -v thunar >/dev/null 2>&1; then
    if command -v dbus-run-session >/dev/null 2>&1; then
      launch_detached dbus-run-session -- thunar --new-window "$SHARE"
    else
      launch_detached thunar --new-window "$SHARE"
    fi
    return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    launch_detached xdg-open "$SHARE"
    return 0
  fi
  notify_user "No file manager is installed for Mac Share."
}

if share_ready; then
  open_file_manager
  exit 0
fi

schedule_recover
sleep 0.5
if share_ready; then
  open_file_manager
  exit 0
fi

notify_user "Mac Share is reconnecting. Try again in a moment if it does not open."
exit 0
EOS
  chmod 0755 /usr/local/libexec/vegpu/vegpu-open-mac-share-worker

  cat >/usr/local/bin/vegpu-open-mac-share <<EOS
#!/usr/bin/env bash
set -u

SHARE="$SHARE"
WORKER=/usr/local/libexec/vegpu/vegpu-open-mac-share-worker

if command -v setsid >/dev/null 2>&1; then
  setsid -f "\$WORKER" "\$SHARE" >/dev/null 2>&1 </dev/null || true
elif command -v nohup >/dev/null 2>&1; then
  nohup "\$WORKER" "\$SHARE" >/dev/null 2>&1 </dev/null &
else
  "\$WORKER" "\$SHARE" >/dev/null 2>&1 </dev/null &
fi

exit 0
EOS
  chmod 0755 /usr/local/bin/vegpu-open-mac-share
}

repair_desktop_links() {
  local desktop_file app_file
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" \
    "/home/$HUMAN_USER/Desktop" \
    "/home/$HUMAN_USER/.config/gtk-3.0" \
    "/home/$HUMAN_USER/.local" \
    "/home/$HUMAN_USER/.local/share" \
    "/home/$HUMAN_USER/.local/share/gvfs-metadata" \
    "/home/$HUMAN_USER/.local/share/applications"

  rm -f /usr/local/bin/vegpu-open-mac-share \
    "/home/$HUMAN_USER/Desktop/Mac Share.desktop" \
    "/home/$HUMAN_USER/.local/share/applications/vegpu-mac-share.desktop"
  remove_managed_mac_share_path "/home/$HUMAN_USER/Mac Share"
  remove_managed_mac_share_path "/home/$HUMAN_USER/Desktop/Mac Share"

  install_mac_share_launcher
  desktop_file="/home/$HUMAN_USER/Desktop/Mac Share.desktop"
  app_file="/home/$HUMAN_USER/.local/share/applications/vegpu-mac-share.desktop"
  cat >"$desktop_file" <<'EOS'
[Desktop Entry]
Version=1.0
Type=Application
Name=Mac Share
Comment=Open the vEGPU Mac share
Exec=/usr/local/bin/vegpu-open-mac-share
Icon=folder-remote
Terminal=false
Categories=Utility;FileManager;
StartupNotify=false
EOS
  cp "$desktop_file" "$app_file"
  chmod 0755 "$desktop_file" "$app_file"
  chown "$HUMAN_USER:$HUMAN_USER" "$desktop_file" "$app_file"
  trust_desktop_file "$HUMAN_USER" "$desktop_file"
  trust_desktop_file "$HUMAN_USER" "$app_file"

  prune_mac_share_bookmarks "/home/$HUMAN_USER/.config/gtk-3.0/bookmarks"
  prune_mac_share_bookmarks "/home/$HUMAN_USER/.gtk-bookmarks"
}

install_display_control() {
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" \
    "/home/$HUMAN_USER/Desktop" \
    "/home/$HUMAN_USER/.config/autostart" \
    "/home/$HUMAN_USER/.local/share/applications"

  cat >/usr/local/sbin/vegpu-display-mode-helper <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

MODE_DIR=/etc/vegpu
MODE_FILE="$MODE_DIR/display-mode.conf"
XORG_CONF=/etc/X11/xorg.conf.d/20-vegpu-virtio-display.conf
NO_IDLE_CONF=/etc/X11/xorg.conf.d/90-vegpu-no-idle.conf
CUSTOMIZATION_SCRIPT=/usr/local/libexec/vegpu/customization.sh
SESSION_ROOT=/run/vegpu-display-sessions
SESSION_STATE_ROOT=/var/lib/vegpu/display-sessions

run_customization() {
  [ -x "$CUSTOMIZATION_SCRIPT" ] || {
    printf 'Missing vEGPU GUI customization script: %s\n' "$CUSTOMIZATION_SCRIPT" >&2
    exit 1
  }
  "$CUSTOMIZATION_SCRIPT" "$@"
}

normalize_bdf() {
  local raw="$1" domain bus slot func
  raw="${raw#pci:}"
  IFS=':.' read -r domain bus slot func <<EOF
$raw
EOF
  domain="${domain: -4}"
  printf '%04x:%02x:%02x.%d\n' "$((16#$domain))" "$((16#$bus))" "$((16#$slot))" "$((10#$func))"
}

xorg_bus_id_from_bdf() {
  local bdf="$1" domain bus slot func
  IFS=':.' read -r domain bus slot func <<EOF
$bdf
EOF
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

write_no_idle_flags() {
  install -d /etc/X11/xorg.conf.d
  cat >"$NO_IDLE_CONF" <<'CONF'
Section "ServerFlags"
    Option "AutoAddGPU" "false"
    Option "AutoBindGPU" "false"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection

Section "Monitor"
    Identifier "Virtual-1"
    Option "DPMS" "false"
EndSection
CONF
}

write_spice_only_xorg() {
  local virtio_busid="$1"
  install -d /etc/X11/xorg.conf.d "$MODE_DIR"
  cat >"$XORG_CONF" <<CONF
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

write_external_primary_xorg() {
  local nvidia_busid="$1"
  install -d /etc/X11/xorg.conf.d "$MODE_DIR"
  cat >"$XORG_CONF" <<CONF
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

restart_lightdm_for_mode() {
  local mode="$1"
  /usr/bin/timeout 20s systemctl stop lightdm || true
  [ -n "$mode" ] || true
  /usr/bin/timeout 20s systemctl start lightdm || true
}

schedule_primary_apply_after_restart() {
  local user uid runuser_bin display_args=()
  command -v systemd-run >/dev/null 2>&1 || return 0
  user="${VEGPU_DISPLAY_USER:-vegpu}"
  uid="$(id -u "$user" 2>/dev/null || true)"
  [ -n "$uid" ] || return 0
  if [ -n "${VEGPU_PRIMARY_DISPLAY:-}" ]; then
    display_args=(DISPLAY="$VEGPU_PRIMARY_DISPLAY")
  fi
  runuser_bin="$(command -v runuser || printf '%s\n' /usr/sbin/runuser)"
  systemctl stop vegpu-display-primary-apply.service >/dev/null 2>&1 || true
  systemctl reset-failed vegpu-display-primary-apply.service >/dev/null 2>&1 || true
  systemd-run --unit=vegpu-display-primary-apply --collect --on-active=8s \
    "$runuser_bin" -u "$user" -- \
      /usr/bin/env "${display_args[@]}" XAUTHORITY="/home/$user/.Xauthority" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" VEGPU_DISPLAY_QUIET=1 \
      /usr/local/bin/vegpu-display-control --apply-primary-display >/dev/null 2>&1 || true
}

write_mode_file() {
  install -d "$MODE_DIR"
  cat >"$MODE_FILE"
  chmod 0644 "$MODE_FILE"
}

current_display_mode() {
  if [ -f "$MODE_FILE" ]; then
    awk -F= '$1 == "VEGPU_DISPLAY_MODE" { print substr($0, index($0, "=") + 1); exit }' "$MODE_FILE" 2>/dev/null || true
  fi
}

active_spice_xorg_has_external_gpu() {
  [ -f /var/log/Xorg.0.log ] || return 1
  grep -Eq 'modeset\(G0\)|NVIDIA\(G0\)' /var/log/Xorg.0.log
}

reconcile_spice_xorg() {
  local mode virtio_bdf before after contaminated=0
  mode="$(current_display_mode)"
  [ "$mode" = "external-primary" ] && return 0

  active_spice_xorg_has_external_gpu && contaminated=1
  before="$(sha256sum "$XORG_CONF" "$NO_IDLE_CONF" 2>/dev/null || true)"
  virtio_bdf="$(detect_virtio_gpu_bdf)"
  write_spice_only_xorg "$(xorg_bus_id_from_bdf "$virtio_bdf")"
  write_no_idle_flags
  write_mode_file <<CONF
VEGPU_DISPLAY_MODE=spice
CONF
  after="$(sha256sum "$XORG_CONF" "$NO_IDLE_CONF" 2>/dev/null || true)"

  if [ "$contaminated" -eq 1 ] || [ "$before" != "$after" ]; then
    restart_lightdm_for_mode spice
  fi
}

json_value() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

gpu_rows() {
  nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv,noheader 2>/dev/null |
    awk -F', *' 'NF >= 3 { printf "%s\t%s\t%s\n", $1, $2, $3 }'
}

session_id_for_bdf() {
  printf 'gpu-%s\n' "$(printf '%s' "$1" | tr '[:.]' '--')"
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
  case "$idx" in
    ''|*[!0-9]*) idx=0 ;;
  esac
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
  case "$number" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ -f "/tmp/.X${number}-lock" ]; then
    pid="$(tr -d ' ' <"/tmp/.X${number}-lock" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  fi
  rm -f "/tmp/.X${number}-lock" "/tmp/.X11-unix/X${number}"
}

session_run_user() {
  local display="$1" xauthority="$2" user uid bus
  shift 2
  user="${VEGPU_DISPLAY_USER:-vegpu}"
  uid="$(id -u "$user" 2>/dev/null || true)"
  bus="/run/user/$uid/bus"
  runuser -u "$user" -- env \
    DISPLAY="$display" \
    XAUTHORITY="$xauthority" \
    HOME="/home/$user" \
    USER="$user" \
    LOGNAME="$user" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$bus}" \
    "$@"
}

primary_session_env() {
  local user target_xauthority pid envlines display xauthority dbus
  user="${VEGPU_DISPLAY_USER:-vegpu}"
  target_xauthority="/home/$user/.Xauthority"
  for pid in $(pgrep -u "$user" xfce4-session 2>/dev/null || true) \
             $(pgrep -u "$user" xfce4-panel 2>/dev/null || true) \
             $(pgrep -u "$user" xfdesktop 2>/dev/null || true); do
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

session_route_primary_input() {
  local role="$1" display xauthority dbus
  IFS=$'\t' read -r display xauthority dbus < <(primary_session_env || true)
  [ -n "${display:-}" ] && [ -n "${xauthority:-}" ] || return 0
  session_route_input_for_display "$display" "$xauthority" "$role" noverify
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

session_configure_outputs() {
  local display="$1" xauthority="$2" outputs output
  outputs="$(session_run_user "$display" "$xauthority" xrandr --query 2>/dev/null | awk '$2 == "connected" { print $1 }' || true)"
  [ -n "$outputs" ] || return 0
  while IFS= read -r output; do
    [ -n "$output" ] || continue
    session_run_user "$display" "$xauthority" xrandr --output "$output" --auto >/dev/null 2>&1 || true
  done <<EOF
$outputs
EOF
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
        "y": int(m.group(5) or 0)
    })
print(json.dumps(outputs))
'
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
    END {
      exit(found && attached ? 0 : 1)
    }
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
  done <<EOF
$ids
EOF
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
  done <<EOF
$ids
EOF
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

session_route_input() {
  local id="$1" role="$2" verify="${3:-noverify}" display xauthority
  session_load_env "$id" || return 0
  display="${DISPLAY_NAME:-}"
  xauthority="${XAUTHORITY_FILE:-}"
  [ -n "$display" ] && [ -n "$xauthority" ] || return 0
  session_route_input_for_display "$display" "$xauthority" "$role" "$verify"
}

session_start() {
  local bdf idx name id display dir state_dir xauthority xorg_log desktop_log busid xorg_bin user uid
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
  user="${VEGPU_DISPLAY_USER:-vegpu}"
  uid="$(id -u "$user" 2>/dev/null || true)"

  install -d -m 0755 "$SESSION_ROOT" "$SESSION_STATE_ROOT" "$dir" "$state_dir" "$dir/xorg.conf.d"
  write_session_xorg_config "$dir/xorg.conf" "$busid"
  if ! [ -f "$xauthority" ]; then
    xauth -f "$xauthority" add "$display" . "$(mcookie)" >/dev/null 2>&1 || true
    chown "$user:$user" "$xauthority" >/dev/null 2>&1 || true
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

  # Let NVIDIA/Xorg choose the initial connected-output layout. XFCE can manage
  # later monitor changes inside this session without vEGPU rewriting positions.
  if ! session_pid_alive "$dir/desktop.pid"; then
    runuser -u "$user" -- env \
      DISPLAY="$display" \
      XAUTHORITY="$xauthority" \
      HOME="/home/$user" \
      USER="$user" \
      LOGNAME="$user" \
      XDG_SESSION_TYPE=x11 \
      dbus-run-session -- sh -lc 'xfce4-session' >"$desktop_log" 2>&1 &
    printf '%s\n' "$!" >"$dir/desktop.pid"
  fi
  session_route_input "$id" off
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

session_reload() {
  local id="$1" display xauthority
  session_load_env "$id"
  session_xorg_running "$id" || session_start "$GPU_BDF" "$GPU_INDEX"
  session_load_env "$id"
  display="$DISPLAY_NAME"
  xauthority="$XAUTHORITY_FILE"
  session_configure_outputs "$display" "$xauthority"
  DISPLAY="$display" XAUTHORITY="$xauthority" run_customization apply-primary-display || true
  session_outputs_json "$id"
}

sessions_json() {
  local first=1 active idx name raw_bdf bdf valid id display running outputs
  install -d -m 0755 "$SESSION_ROOT" "$SESSION_STATE_ROOT"
  active="$(cat "$SESSION_ROOT/active" 2>/dev/null || printf '%s' macos)"
  printf '{"active":%s,"sessions":[' "$(printf '%s' "$active" | json_value)"
  while IFS=$'\t' read -r idx name raw_bdf; do
    [ -n "${raw_bdf:-}" ] || continue
    bdf="$(normalize_bdf "$raw_bdf" 2>/dev/null || printf '%s' "$raw_bdf")"
    valid=false
    gpu_valid_for_bdf "$bdf" && valid=true
    id="$(session_id_for_bdf "$bdf")"
    display="$(session_display_for_index "$idx")"
    running=false
    session_xorg_running "$id" && running=true
    outputs='[]'
    if [ "$running" = true ] && session_load_env "$id"; then
      outputs="$(session_outputs_json_for_display "$DISPLAY_NAME" "$XAUTHORITY_FILE")"
    fi
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"id":%s,"index":%s,"name":%s,"bdf":%s,"display":%s,"state":%s,"active":%s,"valid":%s,"outputs":%s}' \
      "$(printf '%s' "$id" | json_value)" \
      "$(printf '%s' "$idx" | json_value)" \
      "$(printf '%s' "$name" | json_value)" \
      "$(printf '%s' "$bdf" | json_value)" \
      "$(printf '%s' "$display" | json_value)" \
      "$(printf '%s' "$([ "$running" = true ] && printf running || printf stopped)" | json_value)" \
      "$([ "$active" = "$id" ] && printf true || printf false)" \
      "$valid" \
      "$outputs"
  done < <(gpu_rows || true)
  printf ']}\n'
}

cmd="${1:-status}"
case "$cmd" in
  install-global-defaults)
    run_customization install-global-defaults
    ;;
  spice)
    virtio_bdf="$(detect_virtio_gpu_bdf)"
    write_spice_only_xorg "$(xorg_bus_id_from_bdf "$virtio_bdf")"
    write_no_idle_flags
    write_mode_file <<CONF
VEGPU_DISPLAY_MODE=spice
CONF
    restart_lightdm_for_mode spice
    ;;
  boot-spice)
    virtio_bdf="$(detect_virtio_gpu_bdf)"
    write_spice_only_xorg "$(xorg_bus_id_from_bdf "$virtio_bdf")"
    write_no_idle_flags
    run_customization install-global-defaults
    write_mode_file <<CONF
VEGPU_DISPLAY_MODE=spice
CONF
    ;;
  reconcile-spice)
    reconcile_spice_xorg
    ;;
  external-primary)
    nvidia_bdf="$(normalize_bdf "${2:?missing NVIDIA PCI bus id}")"
    nvidia_index="${3:-}"
    validate_nvidia_bdf "$nvidia_bdf"
    write_external_primary_xorg "$(xorg_bus_id_from_bdf "$nvidia_bdf")"
    write_no_idle_flags
    write_mode_file <<CONF
VEGPU_DISPLAY_MODE=external-primary
VEGPU_NVIDIA_BDF=$nvidia_bdf
VEGPU_NVIDIA_INDEX=$nvidia_index
CONF
    schedule_primary_apply_after_restart
    restart_lightdm_for_mode external-primary
    ;;
  reload)
    case "$(current_display_mode)" in
      external-primary)
        schedule_primary_apply_after_restart
        restart_lightdm_for_mode external-primary
        ;;
      *)
        restart_lightdm_for_mode spice
        ;;
    esac
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
  session-reload)
    session_reload "${2:?missing session id}"
    ;;
  session-outputs)
    session_outputs_json "${2:?missing session id}"
    ;;
  *)
    printf 'usage: %s {install-global-defaults|spice|boot-spice|reconcile-spice|external-primary <pci-bdf> [index]|reload|status|sessions --json|session-start <bdf> [index]|session-enter <id>|session-release|session-stop <id>|session-reload <id>|session-outputs <id>}\n' "$0" >&2
    exit 2
    ;;
esac
EOS
  chmod 0755 /usr/local/sbin/vegpu-display-mode-helper

  cat >/etc/systemd/system/vegpu-display-boot-reset.service <<'EOS'
[Unit]
Description=Reset vEGPU display mode to SPICE before the graphical login
After=local-fs.target
Before=display-manager.service lightdm.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vegpu-display-mode-helper boot-spice

[Install]
WantedBy=multi-user.target
EOS
  systemctl enable vegpu-display-boot-reset.service >/dev/null 2>&1 || true

cat >/usr/local/bin/vegpu-display-control <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

MODE_FILE=/etc/vegpu/display-mode.conf
CUSTOMIZATION_SCRIPT=/usr/local/libexec/vegpu/customization.sh

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
  [ -n "${DISPLAY:-}" ] || return 1
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
  IFS=':.' read -r domain bus slot func <<EOF
$raw
EOF
  domain="${domain: -4}"
  printf '%04x:%02x:%02x.%d\n' "$((16#$domain))" "$((16#$bus))" "$((16#$slot))" "$((10#$func))"
}

gpu_rows() {
  nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv,noheader 2>/dev/null |
    awk -F', *' 'NF >= 3 { printf "%s\t%s\t%s\n", $1, $2, $3 }'
}

json_value() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
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
    if gpu_valid_for_bdf "$bdf"; then
      valid=true
    fi
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
  local selected_bdf="$1" selected_index="$2"
  local idx name raw_bdf bdf
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

session_reload() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper session-reload "${1:?missing session id}"
}

session_outputs() {
  sudo -n /usr/local/sbin/vegpu-display-mode-helper session-outputs "${1:?missing session id}"
}

run_customization() {
  [ -x "$CUSTOMIZATION_SCRIPT" ] || {
    printf 'Missing vEGPU GUI customization script: %s\n' "$CUSTOMIZATION_SCRIPT" >&2
    return 1
  }
  "$CUSTOMIZATION_SCRIPT" "$@"
}

main() {
  case "${1:-}" in
    --apply-primary-display)
      session_env
      run_customization apply-primary-display
      return 0
      ;;
    status)
      if [ "${2:-}" = "--json" ]; then
        status_json
      else
        sudo -n /usr/local/sbin/vegpu-display-mode-helper status
      fi
      return 0
      ;;
    list-gpus)
      if [ "${2:-}" = "--json" ]; then
        list_gpus_json
      else
        printf 'usage: %s list-gpus --json\n' "$0" >&2
        return 2
      fi
      return 0
      ;;
    external-primary)
      switch_external_primary "${2:?missing NVIDIA PCI bus id}" "${3:-}"
      return 0
      ;;
    spice)
      switch_spice
      return 0
      ;;
    reload)
      reload_display
      return 0
      ;;
    sessions)
      if [ "${2:-}" = "--json" ]; then
        sessions_json
      else
        printf 'usage: %s sessions --json\n' "$0" >&2
        return 2
      fi
      return 0
      ;;
    session-start)
      session_start "${2:?missing NVIDIA PCI bus id}" "${3:-}"
      return 0
      ;;
    session-enter|session-activate)
      session_enter "${2:?missing session id}"
      return 0
      ;;
    session-release)
      session_release
      return 0
      ;;
    session-stop)
      session_stop "${2:?missing session id}"
      return 0
      ;;
    session-reload)
      session_reload "${2:?missing session id}"
      return 0
      ;;
    session-outputs)
      session_outputs "${2:?missing session id}"
      return 0
      ;;
  esac
}

main "$@"
EOS
  chmod 0755 /usr/local/bin/vegpu-display-control

  cat >/etc/sudoers.d/90-vegpu-display-control <<'EOS'
vegpu ALL=(root) NOPASSWD: /usr/local/sbin/vegpu-display-mode-helper *
EOS
  chmod 0440 /etc/sudoers.d/90-vegpu-display-control
  visudo -cf /etc/sudoers.d/90-vegpu-display-control >/dev/null 2>&1 || rm -f /etc/sudoers.d/90-vegpu-display-control

  find "/home/$HUMAN_USER/.config/autostart" -maxdepth 1 -type f -name 'vegpu-display-*.desktop' -delete
  cat >"/home/$HUMAN_USER/.config/autostart/vegpu-display-apply.desktop" <<'EOS'
[Desktop Entry]
Type=Application
Name=vEGPU Display Apply
Exec=/bin/sh -lc 'sleep 2; /usr/local/bin/vegpu-display-control --apply-primary-display'
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOS
  chown "$HUMAN_USER:$HUMAN_USER" "/home/$HUMAN_USER/.config/autostart/vegpu-display-apply.desktop"

}

repair_spice_agent_session() {
  install -d -o "$HUMAN_USER" -g "$HUMAN_USER" "/home/$HUMAN_USER/.config/autostart"
  cat >"/home/$HUMAN_USER/.config/autostart/spice-vdagent.desktop" <<'EOS'
[Desktop Entry]
Type=Application
Name=SPICE Agent
Exec=/usr/bin/spice-vdagent
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOS
  chown "$HUMAN_USER:$HUMAN_USER" "/home/$HUMAN_USER/.config/autostart/spice-vdagent.desktop"
}

write_root_file_if_changed() {
  local path="$1"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if ! [ -f "$path" ] || ! cmp -s "$tmp" "$path"; then
    install -D -m 0644 "$tmp" "$path"
    XORG_CHANGED=1
  fi
  rm -f "$tmp"
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

xorg_bus_id_from_bdf() {
  local bdf="$1"
  local domain bus slot func
  IFS=':.' read -r domain bus slot func <<EOF
$bdf
EOF
  bus=$((16#$bus))
  slot=$((16#$slot))
  func=$((10#$func))
  printf 'PCI:%d:%d:%d\n' "$bus" "$slot" "$func"
}

display_mode_value() {
  local key="$1"
  [ -f /etc/vegpu/display-mode.conf ] || return 0
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' /etc/vegpu/display-mode.conf
}

force_spice_mode_on_launch() {
  [ "${VEGPU_FORCE_SPICE_ON_LAUNCH:-0}" = "1" ] || return 0
  case "$(display_mode_value VEGPU_DISPLAY_MODE)" in
    external-primary) return 0 ;;
  esac
  install -d /etc/vegpu
  cat >/etc/vegpu/display-mode.conf <<'CONF'
VEGPU_DISPLAY_MODE=spice
CONF
}

write_spice_only_xorg_display() {
  local busid="$1"
  write_root_file_if_changed /etc/X11/xorg.conf.d/20-vegpu-virtio-display.conf <<EOS
Section "ServerFlags"
    Option "AutoAddGPU" "false"
    Option "AutoBindGPU" "false"
EndSection

Section "Device"
    Identifier "vEGPU Virtio Display"
    Driver "modesetting"
    BusID "$busid"
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
EOS
}

write_external_primary_xorg_display() {
  local nvidia_busid="$1"
  write_root_file_if_changed /etc/X11/xorg.conf.d/20-vegpu-virtio-display.conf <<EOS
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
EOS
}

write_no_idle_xorg_display() {
  write_root_file_if_changed /etc/X11/xorg.conf.d/90-vegpu-no-idle.conf <<'EOS'
Section "ServerFlags"
    Option "AutoAddGPU" "false"
    Option "AutoBindGPU" "false"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection

Section "Monitor"
    Identifier "Virtual-1"
    Option "DPMS" "false"
EndSection
EOS
}

configure_virtio_xorg_display() {
  local bdf busid mode nvidia_bdf nvidia_busid
  install -d /etc/X11/xorg.conf.d
  bdf="$(detect_virtio_gpu_bdf)"
  busid="$(xorg_bus_id_from_bdf "$bdf")"
  mode="$(display_mode_value VEGPU_DISPLAY_MODE)"
  nvidia_bdf="$(display_mode_value VEGPU_NVIDIA_BDF)"
  case "$mode" in
    external-primary)
      if [ -n "$nvidia_bdf" ]; then
        nvidia_busid="$(xorg_bus_id_from_bdf "$nvidia_bdf")"
        write_external_primary_xorg_display "$nvidia_busid"
      else
        write_spice_only_xorg_display "$busid"
      fi
      ;;
    *)
      write_spice_only_xorg_display "$busid"
      ;;
  esac
  write_no_idle_xorg_display
}

restart_lightdm_for_display_config() {
  /usr/bin/timeout 20s systemctl restart lightdm || true
}

if [ "${1:-}" = "--install-display-control-only" ]; then
  install_customization_script
  install_scaling_app
  run_customization write-prefs
  run_customization disable-idle
  install_display_control
  /usr/local/sbin/vegpu-display-mode-helper reconcile-spice
  exit 0
fi

install_desktop_stack
configure_desktop_network
force_spice_mode_on_launch
configure_virtio_xorg_display
repair_share_access

install -d /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/90-vegpu-autologin.conf <<'EOS'
[Seat:*]
autologin-user=vegpu
autologin-user-timeout=0
user-session=xfce
greeter-session=lightdm-gtk-greeter
EOS

install -d -o vegpu -g vegpu \
  /home/vegpu/.config/xfce4/xfconf/xfce-perchannel-xml \
  /home/vegpu/.config/autostart

chown -R vegpu:vegpu /home/vegpu/.config
usermod -aG video,render,input,dialout vegpu || true
usermod -aG dialout vegpuctl || true
repair_desktop_links
install_desktop_mount_policy
install_customization_script
install_scaling_app
run_customization write-prefs
install_display_control
repair_spice_agent_session
run_customization apply-boot-defaults

/usr/bin/timeout 20s systemctl enable ssh qemu-guest-agent lightdm || true
/usr/bin/timeout 20s systemctl enable spice-vdagent || true
/usr/bin/timeout 20s systemctl restart qemu-guest-agent || true
/usr/bin/timeout 20s systemctl restart spice-vdagentd || true
restart_lightdm_for_display_config

touch "$MARKER"

#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=/var/lib/vegpu
PACKAGE_DIR=$STATE_DIR/packages
MANIFEST_FILE=$STATE_DIR/manifest.json
LLAMA_RUNTIME_ROOT=/home/vegpu/custom-llama-runtimes
PIN_FILE=/etc/apt/preferences.d/vegpu-kernel-pin
NVIDIA_PIN_FILE=/etc/apt/preferences.d/vegpu-nvidia-pin
NVIDIA_REPO_URL=https://developer.download.nvidia.com/compute/cuda/repos/debian13/sbsa
NVIDIA_KEYRING_URL=$NVIDIA_REPO_URL/cuda-keyring_1.1-1_all.deb
VMNET_GUEST_IP=172.29.253.100
VMNET_GATEWAY=172.29.253.1
VMNET_IFACE=enp0s3
PRIVATE_TCP_PORTS_FILE=$STATE_DIR/private-ports
PRIVATE_UDP_PORTS_FILE=$STATE_DIR/private-ports-udp
LINUX_HOME_EXPORT=/home/vegpu

mkdir -p "$STATE_DIR" "$PACKAGE_DIR"

log() {
  printf '[vegpu-agent] %s\n' "$*" >&2
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
    if printf '%s\n' "$output" | grep -qiE 'dpkg was interrupted|you must manually run.*dpkg --configure -a'; then
      log "dpkg state interrupted; repairing package database ($attempt/120)"
      repair_dpkg_state || true
      sleep 2
      continue
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

dpkg_install() {
  local attempt output code
  output=""
  code=1
  for attempt in $(seq 1 120); do
    set +e
    output="$(dpkg -i "$@" 2>&1)"
    code=$?
    set -e
    if [ "$code" -eq 0 ]; then
      [ -n "$output" ] && printf '%s\n' "$output" >&2
      return 0
    fi
    if printf '%s\n' "$output" | grep -qiE 'dpkg was interrupted|you must manually run.*dpkg --configure -a'; then
      log "dpkg state interrupted; repairing package database ($attempt/120)"
      repair_dpkg_state || true
      sleep 2
      continue
    fi
    if printf '%s\n' "$output" | grep -qiE 'dpkg frontend lock|Unable to acquire the dpkg frontend lock|is another process using it|could not get lock'; then
      log "dpkg lock busy; waiting for current package operation ($attempt/120)"
      sleep 5
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$code"
  done
  printf '%s\n' "$output" >&2
  return "$code"
}

repair_dpkg_state() {
  local output code
  set +e
  output="$(DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>&1)"
  code=$?
  set -e
  [ -n "$output" ] && printf '%s\n' "$output" >&2
  if [ "$code" -ne 0 ]; then
    apt-get -o DPkg::Lock::Timeout=600 -o APT::Get::Lock-Timeout=600 -f install -y
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a
  fi
}

manifest_path() {
  printf '%s\n' "$MANIFEST_FILE"
}

ingest_manifest() {
  local source="$1"
  [ -f "$source" ] || { log "manifest upload missing: $source"; return 1; }
  jq -e '(.manifestVersion == 1 or .manifestVersion == 2) and .id and .debian and .kernel and .driver' "$source" >/dev/null
  install -m 0644 "$source" "$MANIFEST_FILE"
}

ingest_package() {
  local source="$1"
  local relative="$2"
  case "$relative" in
    packages/*) ;;
    *) log "refusing package path outside packages/: $relative"; return 1 ;;
  esac
  [ -f "$source" ] || { log "package upload missing: $source"; return 1; }
  install -d "$STATE_DIR/$(dirname "$relative")"
  install -m 0644 "$source" "$STATE_DIR/$relative"
}

runtime_id() {
  printf '%s\n' "$*" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

runtime_wrapper() {
  local root="$1"
  local rel="$2"
  local executable="$root/$rel"
  local bin_dir
  bin_dir="$(dirname "$executable")"
  cat <<EOF
#!/bin/sh
export LD_LIBRARY_PATH=$bin_dir:$root:$root/lib:\${LD_LIBRARY_PATH:-}
exec "$executable" "\$@"
EOF
}

validate_tar_gz_paths() {
  local archive="$1"
  if tar -tzf "$archive" | grep -E '(^/|(^|/)[.][.](/|$))' >/dev/null; then
    log "refusing unsafe runtime archive paths: $archive"
    return 1
  fi
}

install_seed_llama_runtime_archive() {
  local id="$1"
  local archive="$2"
  local activate="$3"
  local root="$LLAMA_RUNTIME_ROOT/$id"
  local tmp="$root.tmp"
  local server rpc server_rel rpc_rel
  [ -f "$archive" ] || { log "seed llama runtime archive missing: $archive"; return 1; }
  validate_tar_gz_paths "$archive"
  install -d -o vegpu -g vegpu -m 0755 "$LLAMA_RUNTIME_ROOT"
  if [ ! -x "$root/llama-server" ] && ! find "$root" -type f -name llama-server -perm -111 -print -quit 2>/dev/null | grep -q .; then
    rm -rf "$tmp"
    install -d -o vegpu -g vegpu -m 0755 "$tmp"
    tar -xzf "$archive" -C "$tmp"
    server="$(find "$tmp" -type f -name llama-server -print -quit)"
    [ -n "$server" ] || { log "runtime archive has no llama-server: $archive"; rm -rf "$tmp"; return 1; }
    rpc="$(find "$tmp" -type f -name rpc-server -print -quit || true)"
    chmod 0755 "$server"
    [ -n "$rpc" ] && chmod 0755 "$rpc"
    chmod -R u+rwX,go+rX "$tmp"
    chown -R vegpu:vegpu "$tmp"
    rm -rf "$root"
    mv "$tmp" "$root"
  fi
  if [ "$activate" = "true" ]; then
    server="$(find "$root" -type f -name llama-server -print -quit)"
    rpc="$(find "$root" -type f -name rpc-server -print -quit || true)"
    [ -n "$server" ] || { log "installed runtime has no llama-server: $root"; return 1; }
    server_rel="${server#"$root"/}"
    ln -sfn "$root" "$LLAMA_RUNTIME_ROOT/current"
    runtime_wrapper "$LLAMA_RUNTIME_ROOT/current" "$server_rel" >/usr/local/bin/llama-server
    chmod 0755 /usr/local/bin/llama-server
    if [ -n "$rpc" ]; then
      rpc_rel="${rpc#"$root"/}"
      runtime_wrapper "$LLAMA_RUNTIME_ROOT/current" "$rpc_rel" >/usr/local/bin/rpc-server
      chmod 0755 /usr/local/bin/rpc-server
    fi
  fi
}

install_seed_llama_runtimes() {
  local dir="$1"
  local manifest="$dir/llama-runtime-manifest.json"
  local tag pair archive
  [ -f "$manifest" ] || return 0
  tag="$(jq -r '.tag // empty' "$manifest")"
  [ -n "$tag" ] || { log "seed llama runtime manifest has no tag"; return 1; }
  for backend in cuda13 vulkan; do
    archive="$(jq -r --arg backend "$backend" '.assets[$backend].path // empty' "$manifest")"
    [ -n "$archive" ] || { log "seed llama runtime missing $backend archive"; return 1; }
    pair="$(runtime_id "llama-$tag-$backend")"
    install_seed_llama_runtime_archive "$pair-linux" "$dir/$archive" "$([ "$backend" = cuda13 ] && printf true || printf false)"
  done
}

seed_bundle_dir() {
  local base dev
  for base in     /var/lib/cloud/seed/nocloud     /var/lib/cloud/seed/nocloud-net     /run/cloud-init/seed/nocloud     /run/cloud-init/seed/nocloud-net     /run/cloud-init/iso9660     /mnt/vegpu-seed
  do
    if [ -f "$base/vegpu/manifest.json" ]; then
      printf '%s\n' "$base/vegpu"
      return 0
    fi
  done
  dev="$(blkid -L cidata 2>/dev/null || true)"
  if [ -n "$dev" ]; then
    mkdir -p /mnt/vegpu-seed
    mountpoint -q /mnt/vegpu-seed || mount -o ro "$dev" /mnt/vegpu-seed 2>/dev/null || true
    if [ -f /mnt/vegpu-seed/vegpu/manifest.json ]; then
      printf '%s\n' /mnt/vegpu-seed/vegpu
      return 0
    fi
  fi
  return 1
}

ingest_seed_bundle() {
  local bundle
  bundle="$(seed_bundle_dir 2>/dev/null || true)"
  [ -n "$bundle" ] || { log "no vEGPU seed bundle found"; return 0; }
  ingest_manifest "$bundle/manifest.json"
  if [ -d "$bundle/packages" ]; then
    while IFS= read -r -d '' source; do
      local relative
      relative="$(cd "$bundle" && realpath --relative-to="$bundle" "$source")"
      ingest_package "$source" "$relative"
    done < <(find "$bundle/packages" -type f -print0)
  fi
  if [ -d "$bundle/llama-runtimes" ]; then
    install_seed_llama_runtimes "$bundle/llama-runtimes"
  fi
}

update_agent() {
  local source="$1"
  [ -f "$source" ] || { log "agent upload missing: $source"; return 1; }
  install -m 0755 "$source" /usr/local/libexec/vegpu/vegpu-agent
}

manifest_expected_kernel() {
  [ -f "$MANIFEST_FILE" ] || { printf 'unknown\n'; return 0; }
  jq -r '.kernel.version // "unknown"' "$MANIFEST_FILE" 2>/dev/null || printf 'unknown\n'
}

apply_kernel_pin() {
  local expected
  rm -f "$PIN_FILE"
  expected="$(manifest_expected_kernel)"
  if [ -z "$expected" ] || [ "$expected" = "unknown" ]; then
    log "no manifest kernel available; leaving kernel package policy unchanged"
    return 0
  fi
  install -d "$(dirname "$PIN_FILE")"
  cat >"$PIN_FILE" <<EOS
Package: linux-image-arm64 linux-headers-arm64
Pin: version *
Pin-Priority: -1

Package: linux-image-$expected linux-headers-$expected
Pin: version *
Pin-Priority: 1001
EOS
  apt-mark hold linux-image-arm64 linux-headers-arm64 >/dev/null 2>&1 || true
}

remove_kernel_pin() {
  rm -f "$PIN_FILE"
  apt-mark unhold linux-image-arm64 linux-headers-arm64 >/dev/null 2>&1 || true
  dpkg-query -W -f='${Package}\n' 'linux-image-*' 'linux-headers-*' 'linux-kbuild-*' 2>/dev/null | xargs -r apt-mark unhold >/dev/null 2>&1 || true
}

install_dkms_prereqs() {
  export DEBIAN_FRONTEND=noninteractive
  local running_kernel
  running_kernel="$(uname -r)"
  if [ ! -d "/lib/modules/$(uname -r)/build" ]; then
    apt_get update
    apt_get install -y "linux-headers-$running_kernel" ||
      { install_manifest_packages '.kernel.packages' || true; apt_get install -y "linux-headers-$running_kernel" || true; }
  fi
  apt_get install -y dkms build-essential kmod
}

setup_dkms_autorebuild() {
  install -d /etc/systemd/system /etc/apt/apt.conf.d "$STATE_DIR"
  cat >/etc/systemd/system/vegpu-dkms-refresh.service <<'EOS'
[Unit]
Description=Rebuild vEGPU DKMS modules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/vegpu/vegpu-agent dkms-refresh
EOS

  cat >/etc/systemd/system/vegpu-dkms-refresh.timer <<'EOS'
[Unit]
Description=Run vEGPU DKMS refresh after boot and periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=12h
Persistent=true

[Install]
WantedBy=timers.target
EOS

  cat >/etc/apt/apt.conf.d/99-vegpu-dkms-refresh <<'EOS'
DPkg::Post-Invoke { "mkdir -p /var/lib/vegpu; touch /var/lib/vegpu/dkms-refresh-needed; if command -v systemd-run >/dev/null 2>&1; then systemd-run --unit=vegpu-dkms-refresh-apt --on-active=2min /usr/local/libexec/vegpu/vegpu-agent dkms-refresh >/dev/null 2>&1 || true; fi"; };
EOS

  systemctl daemon-reload || true
  systemctl enable --now vegpu-dkms-refresh.timer || true
}

ensure_driver_persistence() {
  install -d /etc/modules-load.d /etc/initramfs-tools "$STATE_DIR"
  printf 'apple_dma\n' >/etc/modules-load.d/apple-dma-load.conf
  touch /etc/initramfs-tools/modules
  grep -qxF apple_dma /etc/initramfs-tools/modules || printf 'apple_dma\n' >>/etc/initramfs-tools/modules
  depmod -a || true
  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k "$(uname -r)" || true
  fi
  touch "$STATE_DIR/driver-persistent"
}

configure_nvidia_repos() {
  mkdir -p /etc/modprobe.d /etc/apt/preferences.d
  if [ -f /etc/modprobe.d/blacklist-nouveau.conf ] &&
     [ -f "$NVIDIA_PIN_FILE" ] &&
     grep -Fq '*nvidia* libcuda* libnv* libxnv*' "$NVIDIA_PIN_FILE" &&
     [ -f /etc/apt/sources.list.d/cuda-debian13-sbsa.list ]; then
    return 0
  fi

  cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOS'
blacklist nouveau
options nouveau modeset=0
EOS

  apt_get update
  apt_get install -y ca-certificates curl gnupg
  curl -fsSL "$NVIDIA_KEYRING_URL" -o /tmp/cuda-keyring.deb
  dpkg_install /tmp/cuda-keyring.deb
  rm -f /tmp/cuda-keyring.deb

  cat >"$NVIDIA_PIN_FILE" <<'EOS'
Package: *nvidia* libcuda* libnv* libxnv*
Pin: version 595*
Pin-Priority: 1002

Package: cuda cuda-* libcudnn* libnccl* nsight*
Pin: origin developer.download.nvidia.com
Pin-Priority: 1001

Package: *nvidia* libcuda* libnv* libxnv*
Pin: origin developer.download.nvidia.com
Pin-Priority: 1001
EOS

  apt_get update
  for package in nvidia-driver-pinning-595.71.05 nvidia-open cuda-toolkit-13-2; do
    apt-cache show "$package" >/dev/null || { log "NVIDIA package not resolvable after repo setup: $package"; return 1; }
  done
  if dpkg-query -W xserver-xorg-video-nouveau >/dev/null 2>&1; then
    apt_get purge -y xserver-xorg-video-nouveau || true
  fi
}

install_nvidia_stack() {
  configure_nvidia_repos
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt_get install -y --allow-downgrades     -o Dpkg::Options::=--force-confdef     -o Dpkg::Options::=--force-confold     nvidia-driver-pinning-595.71.05     nvidia-open=595.71.05-1     cuda-toolkit-13-2=13.2.1-1
  modprobe nvidia || true
  modprobe nvidia_uvm || true
}

validate_port() {
  local port="$1"
  local protocol="${2:-tcp}"
  case "$port" in
    ''|*[!0-9]*) log "invalid $protocol port: $port"; return 1 ;;
  esac
  [ "$port" -gt 0 ] && [ "$port" -lt 65536 ] || { log "$protocol port out of range: $port"; return 1; }
}

delete_iptables_rule() {
  local table=filter
  if [ "${1:-}" = "-t" ]; then
    table="$2"
    shift 2
  fi
  local chain="$1"
  shift
  while iptables -t "$table" -D "$chain" "$@" 2>/dev/null; do :; done
}

private_ports_file() {
  case "${1:-tcp}" in
    tcp) printf '%s\n' "$PRIVATE_TCP_PORTS_FILE" ;;
    udp) printf '%s\n' "$PRIVATE_UDP_PORTS_FILE" ;;
    *) log "unsupported private port protocol: $1"; return 1 ;;
  esac
}

remember_private_port() {
  local port="$1"
  local protocol="${2:-tcp}"
  local file
  file="$(private_ports_file "$protocol")"
  install -d "$STATE_DIR"
  touch "$file"
  grep -qxF "$port" "$file" || printf '%s\n' "$port" >>"$file"
  sort -n -u "$file" -o "$file"
}

apply_private_port() {
  local port="$1"
  local protocol="${2:-tcp}"
  case "$protocol" in
    tcp|udp) ;;
    *) log "unsupported private port protocol: $protocol"; return 1 ;;
  esac
  validate_port "$port" "$protocol"
  remember_private_port "$port" "$protocol"
  delete_iptables_rule -t raw PREROUTING -i "$VMNET_IFACE" -p "$protocol" ! -s "$VMNET_GATEWAY" -d "$VMNET_GUEST_IP" --dport "$port" -j DROP
  delete_iptables_rule INPUT -i "$VMNET_IFACE" -p "$protocol" -s "$VMNET_GATEWAY" --dport "$port" -j ACCEPT
  delete_iptables_rule INPUT -i "$VMNET_IFACE" -p "$protocol" --dport "$port" -j DROP
  iptables -t raw -I PREROUTING 1 -i "$VMNET_IFACE" -p "$protocol" ! -s "$VMNET_GATEWAY" -d "$VMNET_GUEST_IP" --dport "$port" -j DROP
  iptables -I INPUT 1 -i "$VMNET_IFACE" -p "$protocol" --dport "$port" -j DROP
  iptables -I INPUT 1 -i "$VMNET_IFACE" -p "$protocol" -s "$VMNET_GATEWAY" --dport "$port" -j ACCEPT
}

apply_private_network() {
  local ports=(22)
  if [ -f "$PRIVATE_TCP_PORTS_FILE" ]; then
    mapfile -t ports < <({ printf '%s\n' 22; cat "$PRIVATE_TCP_PORTS_FILE"; } | sort -n -u)
  fi
  for port in "${ports[@]}"; do
    [ -n "$port" ] || continue
    apply_private_port "$port" tcp
  done
  if [ -f "$PRIVATE_UDP_PORTS_FILE" ]; then
    mapfile -t ports < <(sort -n -u "$PRIVATE_UDP_PORTS_FILE")
    for port in "${ports[@]}"; do
      [ -n "$port" ] || continue
      apply_private_port "$port" udp
    done
  fi
}

configure_private_network() {
  install -d /etc/ssh/sshd_config.d /etc/systemd/system
  cat >/etc/ssh/sshd_config.d/90-vegpu-vmnet.conf <<EOS
ListenAddress $VMNET_GUEST_IP
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowUsers vegpu@$VMNET_GATEWAY vegpuctl@$VMNET_GATEWAY
EOS

  cat >/etc/systemd/system/vegpu-private-network.service <<'EOS'
[Unit]
Description=Apply vEGPU private vmnet firewall rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/vegpu/vegpu-agent apply-private-network

[Install]
WantedBy=multi-user.target
EOS

  systemctl daemon-reload || true
  systemctl enable --now vegpu-private-network.service || apply_private_network
  sshd -t
  systemctl restart ssh || systemctl restart sshd || true
  touch "$STATE_DIR/private-network-configured"
}

configure_audio_rtp() {
  local mac_host="${1:-$VMNET_GATEWAY}"
  local vm_to_mac_port="${2:-47110}"
  local mac_to_vm_port="${3:-47111}"
  case "$vm_to_mac_port:$mac_to_vm_port" in
    *[!0-9:]*|:*) log "invalid audio RTP ports"; return 1 ;;
  esac

  install -d -o vegpu -g vegpu \
    "$LINUX_HOME_EXPORT/.config/pipewire/pipewire.conf.d" \
    "$LINUX_HOME_EXPORT/.config/systemd/user"

  cat >/usr/local/libexec/vegpu/vegpu-audio-defaults <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

find_node_id() {
  local name="$1"
  pw-dump 2>/dev/null | jq -r --arg name "$name" '
    .[]
    | select(.type == "PipeWire:Interface:Node")
    | select(.info.props."node.name" == $name)
    | .id
  ' | head -1
}

for _ in $(seq 1 60); do
  sink="$(find_node_id vegpu-rtp-mac-speakers || true)"
  source="$(find_node_id vegpu-rtp-mac-microphone || true)"
  [ -n "$sink" ] && wpctl set-default "$sink" >/dev/null 2>&1 || true
  [ -n "$source" ] && wpctl set-default "$source" >/dev/null 2>&1 || true
  [ -n "$sink" ] && [ -n "$source" ] && exit 0
  sleep 1
done
exit 0
EOS
  chmod 0755 /usr/local/libexec/vegpu/vegpu-audio-defaults

  cat >"$LINUX_HOME_EXPORT/.config/pipewire/pipewire.conf.d/50-vegpu-rtp-audio.conf" <<EOS
context.modules = [
  { name = libpipewire-module-rtp-sink
    args = {
      source.ip = "0.0.0.0"
      destination.ip = "$mac_host"
      destination.port = $vm_to_mac_port
      net.mtu = 1280
      net.ttl = 1
      sess.min-ptime = 5
      sess.max-ptime = 5
      rtp.ptime = 5
      sess.latency.msec = 20
      sess.name = "vEGPU Mac Speakers"
      sess.media = "audio"
      audio.format = "S16BE"
      audio.rate = 48000
      audio.channels = 2
      audio.position = [ FL FR ]
      stream.props = {
        node.name = "vegpu-rtp-mac-speakers"
        node.description = "vEGPU Mac Speakers"
        media.class = "Audio/Sink"
        node.virtual = true
      }
    }
  }
  { name = libpipewire-module-rtp-source
    args = {
      source.ip = "0.0.0.0"
      source.port = $mac_to_vm_port
      node.always-process = true
      stream.may-pause = false
      sess.latency.msec = 40
      sess.ignore-ssrc = true
      sess.media = "audio"
      audio.format = "S16BE"
      audio.rate = 48000
      audio.channels = 2
      audio.position = [ FL FR ]
      stream.props = {
        node.name = "vegpu-rtp-mac-microphone"
        node.description = "vEGPU Mac Microphone"
        media.class = "Audio/Source"
        node.virtual = true
      }
    }
  }
]
EOS
  chown vegpu:vegpu "$LINUX_HOME_EXPORT/.config/pipewire/pipewire.conf.d/50-vegpu-rtp-audio.conf"
  chmod 0644 "$LINUX_HOME_EXPORT/.config/pipewire/pipewire.conf.d/50-vegpu-rtp-audio.conf"

  cat >"$LINUX_HOME_EXPORT/.config/systemd/user/vegpu-audio-defaults.service" <<'EOS'
[Unit]
Description=Select vEGPU RTP audio devices
After=pipewire.service wireplumber.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/vegpu/vegpu-audio-defaults

[Install]
WantedBy=default.target
EOS
  chown vegpu:vegpu "$LINUX_HOME_EXPORT/.config/systemd/user/vegpu-audio-defaults.service"
  chmod 0644 "$LINUX_HOME_EXPORT/.config/systemd/user/vegpu-audio-defaults.service"
  install -d -o vegpu -g vegpu "$LINUX_HOME_EXPORT/.config/systemd/user/default.target.wants"
  ln -sf ../vegpu-audio-defaults.service "$LINUX_HOME_EXPORT/.config/systemd/user/default.target.wants/vegpu-audio-defaults.service"
  chown -h vegpu:vegpu "$LINUX_HOME_EXPORT/.config/systemd/user/default.target.wants/vegpu-audio-defaults.service" 2>/dev/null || true

  loginctl enable-linger vegpu >/dev/null 2>&1 || true
  local uid
  uid="$(id -u vegpu)"
  if [ -d "/run/user/$uid" ]; then
    runuser -u vegpu -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user daemon-reload >/dev/null 2>&1 || true
    runuser -u vegpu -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user enable vegpu-audio-defaults.service >/dev/null 2>&1 || true
    runuser -u vegpu -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user restart pipewire pipewire-pulse wireplumber >/dev/null 2>&1 || true
    runuser -u vegpu -- env XDG_RUNTIME_DIR="/run/user/$uid" /usr/local/libexec/vegpu/vegpu-audio-defaults >/dev/null 2>&1 || true
  fi
  apply_private_port "$mac_to_vm_port" udp || true
  touch "$STATE_DIR/audio-rtp-configured"
}

ensure_ml_cache_policy() {
  install -d "$LINUX_HOME_EXPORT"
  chown vegpu:vegpu "$LINUX_HOME_EXPORT" 2>/dev/null || true
  install -d -o vegpu -g vegpu \
    "$LINUX_HOME_EXPORT/.cache" \
    "$LINUX_HOME_EXPORT/.cache/huggingface" \
    "$LINUX_HOME_EXPORT/.cache/huggingface/hub" \
    "$LINUX_HOME_EXPORT/.cache/huggingface/transformers" \
    "$LINUX_HOME_EXPORT/.cache/huggingface/diffusers" \
    "$LINUX_HOME_EXPORT/.cache/torch" \
    "$LINUX_HOME_EXPORT/Models" \
    "$LINUX_HOME_EXPORT/Apps" \
    "$LINUX_HOME_EXPORT/Workflows" \
    "$LINUX_HOME_EXPORT/Outputs"

  cat >/etc/profile.d/vegpu-ml-cache.sh <<'EOS'
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-$HOME/.cache/huggingface/transformers}"
export DIFFUSERS_CACHE="${DIFFUSERS_CACHE:-$HOME/.cache/huggingface/diffusers}"
export TORCH_HOME="${TORCH_HOME:-$HOME/.cache/torch}"
EOS
  chmod 0644 /etc/profile.d/vegpu-ml-cache.sh

  install -d /etc/environment.d
  cat >/etc/environment.d/90-vegpu-ml-cache.conf <<'EOS'
XDG_CACHE_HOME=/home/vegpu/.cache
HF_HOME=/home/vegpu/.cache/huggingface
HF_HUB_CACHE=/home/vegpu/.cache/huggingface/hub
TRANSFORMERS_CACHE=/home/vegpu/.cache/huggingface/transformers
DIFFUSERS_CACHE=/home/vegpu/.cache/huggingface/diffusers
TORCH_HOME=/home/vegpu/.cache/torch
EOS
  chmod 0644 /etc/environment.d/90-vegpu-ml-cache.conf
}

configure_linux_home_nfs_ports() {
  install -d /etc/modprobe.d
  cat >/etc/modprobe.d/90-vegpu-lockd.conf <<'EOS'
options lockd nlm_tcpport=32768 nlm_udpport=32768
EOS
  touch /etc/nfs.conf
  if ! grep -q '^\[mountd\]' /etc/nfs.conf 2>/dev/null; then
    cat >>/etc/nfs.conf <<'EOS'

[mountd]
port=20048

[statd]
port=32765
outgoing-port=32766
EOS
  else
    sed -i '/^\[mountd\]/,/^\[/ s/^#\?port=.*/port=20048/' /etc/nfs.conf || true
    sed -i '/^\[statd\]/,/^\[/ s/^#\?port=.*/port=32765/' /etc/nfs.conf || true
  fi
}

export_linux_home_nfs() {
  export DEBIAN_FRONTEND=noninteractive
  ensure_ml_cache_policy
  apt_get update
  apt_get install -y nfs-kernel-server rpcbind
  configure_linux_home_nfs_ports
  local uid gid
  uid="$(id -u vegpu)"
  gid="$(id -g vegpu)"
  install -d /etc/exports.d
  cat >/etc/exports.d/vegpu-home.exports <<EOS
$LINUX_HOME_EXPORT $VMNET_GATEWAY(rw,sync,no_subtree_check,all_squash,anonuid=$uid,anongid=$gid,insecure)
EOS
  systemctl enable --now rpcbind || true
  systemctl enable --now nfs-server || systemctl enable --now nfs-kernel-server || true
  systemctl restart nfs-server || systemctl restart nfs-kernel-server || true
  exportfs -ra
  for port in 111 2049 20048 32765 32766 32768; do
    apply_private_port "$port" tcp || true
    apply_private_port "$port" udp || true
  done
  touch "$STATE_DIR/linux-home-nfs-exported"
}

verify_package() {
  local file="$1"
  local expected="$2"
  [ -f "$file" ] || { log "missing package $file"; return 1; }
  if [ -n "$expected" ] && [ "$expected" != "null" ]; then
    local actual
    actual="$(sha512sum "$file" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || {
      log "sha512 mismatch for $file"
      log "expected $expected"
      log "actual   $actual"
      return 1
    }
  fi
}

install_manifest_packages() {
  local jq_filter="$1"
  local manifest
  manifest="$(manifest_path)"
  [ -f "$manifest" ] || return 0
  mapfile -t rows < <(jq -r "$jq_filter[]? | if type == \"string\" then [. , \"\"] else [.path, (.sha512 // \"\")] end | @tsv" "$manifest")
  [ "${#rows[@]}" -gt 0 ] || return 0
  local files=()
  for row in "${rows[@]}"; do
    local rel expected file
    rel="$(printf '%s' "$row" | cut -f1)"
    expected="$(printf '%s' "$row" | cut -f2)"
    file="$STATE_DIR/$rel"
    verify_package "$file" "$expected"
    files+=("$file")
  done
  if [ "${#files[@]}" -gt 0 ]; then
    repair_dpkg_state || true
    dpkg_install "${files[@]}" || apt_get -f install -y
    repair_dpkg_state || true
  fi
}

kernel_package_tokens() {
  local kernel="$1"
  local token alt
  token="${kernel/+/-}"
  printf '%s\n' "$token"
  alt="$(printf '%s\n' "$kernel" | sed -E 's/\+deb([0-9]+)\.[0-9]+-/+deb\1-/')"
  alt="${alt/+/-}"
  if [ "$alt" != "$token" ]; then
    printf '%s\n' "$alt"
  fi
}

is_driver_module_package() {
  local file="$1"
  local package
  package="$(dpkg-deb -f "$file" Package 2>/dev/null || basename "$file")"
  case "$package" in
    apple-dma-modules-*|vegpu-guest-dma-modules-*) return 0 ;;
    *) return 1 ;;
  esac
}

driver_module_package_matches_kernel() {
  local file="$1"
  local kernel="$2"
  local package token
  package="$(dpkg-deb -f "$file" Package 2>/dev/null || basename "$file")"
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    case "$package $file" in
      *"$token"*) return 0 ;;
    esac
  done < <(kernel_package_tokens "$kernel")
  return 1
}

install_driver_prebuilt_for_kernel() {
  local kernel="$1"
  local manifest
  manifest="$(manifest_path)"
  [ -f "$manifest" ] || return 1
  mapfile -t rows < <(jq -r '.driver.prebuiltPackages[]? | if type == "string" then [. , ""] else [.path, (.sha512 // "")] end | @tsv' "$manifest")
  [ "${#rows[@]}" -gt 0 ] || return 1
  local files=()
  for row in "${rows[@]}"; do
    local rel expected file
    rel="$(printf '%s' "$row" | cut -f1)"
    expected="$(printf '%s' "$row" | cut -f2)"
    file="$STATE_DIR/$rel"
    verify_package "$file" "$expected"
    if is_driver_module_package "$file" && ! driver_module_package_matches_kernel "$file" "$kernel"; then
      log "skipping prebuilt driver package for another kernel: $(basename "$file")"
      continue
    fi
    files+=("$file")
  done
  [ "${#files[@]}" -gt 0 ] || return 1
  repair_dpkg_state || true
  dpkg_install "${files[@]}" || apt_get -f install -y
  repair_dpkg_state || true
}

disable_idle() {
  local human_user=vegpu
  local home=/home/vegpu

  log "installing no-sleep/no-idle guest policy"

  install -d /etc/systemd/logind.conf.d /etc/systemd/sleep.conf.d /etc/X11/xorg.conf.d /usr/local/libexec/vegpu

  if command -v systemctl >/dev/null 2>&1; then
    timeout 15s systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
    timeout 15s systemctl disable --now light-locker xfce4-screensaver xscreensaver >/dev/null 2>&1 || true
  fi

  cat >/etc/systemd/logind.conf.d/90-vegpu-no-sleep.conf <<'EOS'
[Login]
IdleAction=ignore
IdleActionSec=infinity
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOS

  cat >/etc/systemd/sleep.conf.d/90-vegpu-no-sleep.conf <<'EOS'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
EOS

  cat >/etc/X11/xorg.conf.d/90-vegpu-no-idle.conf <<'EOS'
Section "ServerFlags"
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

  cat >/usr/local/libexec/vegpu/no-idle-session.sh <<'EOS'
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
  chmod 0755 /usr/local/libexec/vegpu/no-idle-session.sh

  if [ -d "$home" ]; then
    install -d -o "$human_user" -g "$human_user" "$home/.config/autostart"
    cat >"$home/.config/autostart/vegpu-no-idle.desktop" <<'EOS'
[Desktop Entry]
Type=Application
Name=vEGPU No Idle Lock
Exec=/usr/local/libexec/vegpu/no-idle-session.sh
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOS
    chown "$human_user:$human_user" "$home/.config/autostart/vegpu-no-idle.desktop" || true
  fi

  if [ -x /usr/local/libexec/vegpu/customization.sh ]; then
    /usr/local/libexec/vegpu/customization.sh disable-idle >/dev/null 2>&1 || true
  fi

  if command -v systemctl >/dev/null 2>&1; then
    timeout 15s systemctl daemon-reload >/dev/null 2>&1 || true
    timeout 15s systemctl restart systemd-logind >/dev/null 2>&1 || true
  fi
}

update_tools() {
  disable_idle
  [ -f "$MANIFEST_FILE" ] || { log "manifest has not been pushed by vEGPU yet"; return 0; }
  install_manifest_packages '.guestPackages'
  disable_idle
  touch "$STATE_DIR/tools-updated"
}

install_driver() {
  [ -f "$MANIFEST_FILE" ] || { log "manifest has not been pushed by vEGPU yet"; return 1; }
  setup_dkms_autorebuild
  ensure_driver_persistence
  if modprobe apple_dma 2>/dev/null || modprobe vegpu_guest_dma 2>/dev/null; then
    ensure_driver_persistence
    return 0
  fi
  local driver_package_count
  driver_package_count="$(jq '[.driver.prebuiltPackages[]?, .driver.dkmsPackages[]?] | length' "$MANIFEST_FILE")"
  if [ "$driver_package_count" = "0" ]; then
    log "manifest has no guest DMA driver packages"
    return 1
  fi
  if install_driver_prebuilt_for_kernel "$(uname -r)"; then
    ensure_driver_persistence
    depmod -a || true
    if modprobe apple_dma 2>/dev/null || modprobe vegpu_guest_dma 2>/dev/null; then
      ensure_driver_persistence
      return 0
    fi
  else
    log "no prebuilt guest DMA driver package matched kernel $(uname -r); falling back to DKMS"
  fi

  install_dkms_prereqs
  install_manifest_packages '.driver.dkmsPackages'
  dkms autoinstall || true
  ensure_driver_persistence
  depmod -a || true
  modprobe apple_dma 2>/dev/null || modprobe vegpu_guest_dma 2>/dev/null || true
  if lsmod | awk '{print $1}' | grep -qxE 'apple_dma|vegpu_guest_dma'; then
    ensure_driver_persistence
    rm -f "$STATE_DIR/dkms-refresh-needed"
    return 0
  fi
  log "guest DMA driver module is not loaded after install"
  status_json >&2 || true
  rm -f "$STATE_DIR/dkms-refresh-needed"
  return 1
}

dkms_refresh() {
  setup_dkms_autorebuild
  [ -f "$MANIFEST_FILE" ] || { log "manifest has not been pushed by vEGPU yet"; return 0; }
  local driver_package_count
  driver_package_count="$(jq '[.driver.prebuiltPackages[]?, .driver.dkmsPackages[]?] | length' "$MANIFEST_FILE")"
  if [ "$driver_package_count" = "0" ]; then
    log "manifest has no guest DMA driver packages"
    return 0
  fi
  install_dkms_prereqs
  install_manifest_packages '.driver.dkmsPackages'
  dkms autoinstall -k "$(uname -r)" || dkms autoinstall || true
  ensure_driver_persistence
  depmod -a || true
  modprobe apple_dma 2>/dev/null || modprobe vegpu_guest_dma 2>/dev/null || true
  status_json >"$STATE_DIR/dkms-refresh-status.json" || true
  rm -f "$STATE_DIR/dkms-refresh-needed"
}

update_kernel() {
  [ -f "$MANIFEST_FILE" ] || { log "manifest has not been pushed by vEGPU yet"; return 1; }
  remove_kernel_pin
  install_manifest_packages '.kernel.packages'
  install_driver
  apply_kernel_pin
  touch "$STATE_DIR/reboot-required"
}

ensure_nfs_client() {
  if command -v mount.nfs >/dev/null 2>&1 || command -v mount.nfs4 >/dev/null 2>&1; then
    return 0
  fi
  apt_get update
  apt_get install -y nfs-common
}

nfs_mount_source() {
  local target="$1"
  awk -v target="$target" '$5 == target {
    for (i = 1; i <= NF; i++) {
      if ($i == "-") {
        if ($(i + 1) == "nfs" || $(i + 1) == "nfs4") {
          found = 1
          print $(i + 2)
          exit
        }
        if (fallback == "") {
          fallback = $(i + 2)
        }
      }
    }
  }
  END {
    if (!found && fallback != "") {
      print fallback
    }
  }' /proc/self/mountinfo 2>/dev/null || true
}

repair_share_user_access() {
  local target="$1"
  local group_name=""
  usermod -aG dialout vegpu 2>/dev/null || true
  usermod -aG dialout vegpuctl 2>/dev/null || true
  if [ -e "$target" ]; then
    local gid
    gid="$(stat -c '%g' "$target" 2>/dev/null || true)"
    if [ -n "$gid" ]; then
      group_name="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"
    fi
  fi
  if [ -n "$group_name" ]; then
    usermod -aG "$group_name" vegpu 2>/dev/null || true
    usermod -aG "$group_name" vegpuctl 2>/dev/null || true
  fi
  if id vegpu >/dev/null 2>&1; then
    install -d -o vegpu -g vegpu /home/vegpu/Desktop /home/vegpu/.config/gtk-3.0 /home/vegpu/.local/share/applications
    cat >/usr/local/bin/vegpu-open-mac-share <<EOS
#!/usr/bin/env bash
set -euo pipefail

SHARE="$target"

notify_user() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "vEGPU" "\$1" 2>/dev/null || true
  else
    printf '%s\n' "\$1" >&2
  fi
}

if ! /usr/bin/timeout 8s /bin/sh -c 'stat "\$1" >/dev/null && ls -ld "\$1/." >/dev/null' sh "\$SHARE"; then
  notify_user "Mac Share is not responding. Use Repair mounts in vEGPU, then open Mac Share again."
  exit 1
fi

exec xdg-open "\$SHARE"
EOS
    chmod 0755 /usr/local/bin/vegpu-open-mac-share

    for path in "/home/vegpu/Mac Share" "/home/vegpu/Desktop/Mac Share"; do
      if [ -L "$path" ] || [ -f "$path" ]; then
        rm -f "$path"
      fi
    done
    ln -sfn "$target" "/home/vegpu/Mac Share"
    chown -h vegpu:vegpu "/home/vegpu/Mac Share"

    cat >"/home/vegpu/Desktop/Mac Share.desktop" <<'EOS'
[Desktop Entry]
Version=1.0
Type=Application
Name=Mac Share
Comment=Open the vEGPU Mac share
Exec=/usr/local/bin/vegpu-open-mac-share
Icon=folder-remote
Terminal=false
Categories=Utility;FileManager;
StartupNotify=true
EOS
    cp "/home/vegpu/Desktop/Mac Share.desktop" "/home/vegpu/.local/share/applications/vegpu-mac-share.desktop"
    chmod 0755 "/home/vegpu/Desktop/Mac Share.desktop" "/home/vegpu/.local/share/applications/vegpu-mac-share.desktop"
    chown vegpu:vegpu "/home/vegpu/Desktop/Mac Share.desktop" "/home/vegpu/.local/share/applications/vegpu-mac-share.desktop"
    sudo -u vegpu env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u vegpu)/bus gio set "/home/vegpu/Desktop/Mac Share.desktop" metadata::trusted true >/dev/null 2>&1 || true
    if command -v xdg-mime >/dev/null 2>&1 && [ -f /usr/share/applications/org.kde.dolphin.desktop ]; then
      sudo -u vegpu xdg-mime default org.kde.dolphin.desktop inode/directory >/dev/null 2>&1 || true
    fi

    if [ -f /home/vegpu/.config/gtk-3.0/bookmarks ]; then
      tmp="$(mktemp)"
      awk -v raw="file://$target Mac Share" '$0 != raw { print }' /home/vegpu/.config/gtk-3.0/bookmarks >"$tmp"
      install -o vegpu -g vegpu -m 0644 "$tmp" /home/vegpu/.config/gtk-3.0/bookmarks
      rm -f "$tmp"
    fi
  fi
}

mount_nfs_share() {
  local host="$1"
  local export_path="$2"
  local target="$3"
  local source="$host:$export_path"
  local opts="vers=3,tcp,nolock,noatime,soft,timeo=50,retrans=2,rsize=65536,wsize=65536"
  local mount_unit automount_unit current
  ensure_nfs_client
  mount_unit="$(systemd-escape --path --suffix=mount "$target")"
  automount_unit="$(systemd-escape --path --suffix=automount "$target")"
  mkdir -p "$target" /etc/systemd/system

  cat >"/etc/systemd/system/$mount_unit" <<EOS
[Unit]
Description=vEGPU Mac share
After=network-online.target
Wants=network-online.target

[Mount]
What=$source
Where=$target
Type=nfs
Options=$opts

[Install]
WantedBy=multi-user.target
EOS

  cat >"/etc/systemd/system/$automount_unit" <<EOS
[Unit]
Description=vEGPU Mac share automount
After=network-online.target
Wants=network-online.target

[Automount]
Where=$target
TimeoutIdleSec=300

[Install]
WantedBy=multi-user.target
EOS

  systemctl daemon-reload || true
  current="$(nfs_mount_source "$target")"
  if [ -n "$current" ]; then
    if [ "$current" = "$source" ] &&
       timeout 8 sh -c 'stat "$1" >/dev/null && ls -ld "$1/." >/dev/null' sh "$target"; then
      timeout 3 umount "$target" 2>/dev/null || { repair_share_user_access "$target"; return 0; }
    else
      log "Replacing stale or wrong NFS share mount at $target (current: $current, expected: $source)"
      timeout 8 umount -f "$target" 2>/dev/null || timeout 8 umount -l "$target" 2>/dev/null || true
    fi
  fi

  systemctl reset-failed "$automount_unit" "$mount_unit" >/dev/null 2>&1 || true
  systemctl enable "$automount_unit" >/dev/null 2>&1 || true
  systemctl start "$automount_unit" >/dev/null 2>&1 || true
  if timeout 8 sh -c 'stat "$1" >/dev/null && ls -ld "$1/." >/dev/null' sh "$target" &&
     [ "$(nfs_mount_source "$target")" = "$source" ]; then
    repair_share_user_access "$target"
    return 0
  fi

  log "Automount probe failed for $target; trying direct NFS mount"
  systemctl reset-failed "$automount_unit" "$mount_unit" >/dev/null 2>&1 || true
  systemctl start "$mount_unit" || mount -t nfs -o "$opts" "$source" "$target"
  current="$(nfs_mount_source "$target")"
  [ "$current" = "$source" ] || { log "NFS share mount verification failed: expected $source, saw ${current:-missing}"; return 1; }
  timeout 8 sh -c 'stat "$1" >/dev/null && ls -ld "$1/." >/dev/null' sh "$target" ||
    { log "NFS share metadata verification failed for $target"; return 1; }
  repair_share_user_access "$target"
}

status_json() {
  local manifest="none"
  local manifest_id="none"
  local expected_kernel="unknown"
  local kernel_match="unknown"
  local module_loaded="no"
  local driver_ready="no"
  local driver_installed="no"
  local driver_persistent="no"
  local passthrough_ready="no"
  local bound_devices=""
  local bound_count=0
  local dma_device_present="no"
  local driver_error=""
  manifest="$(manifest_path)"
  if [ -f "$manifest" ]; then
    manifest_id="$(jq -r '.id // "unknown"' "$manifest" 2>/dev/null || printf unknown)"
    expected_kernel="$(jq -r '.kernel.version // "unknown"' "$manifest" 2>/dev/null || printf unknown)"
    if [ "$expected_kernel" = "$(uname -r)" ]; then kernel_match="yes"; else kernel_match="no"; fi
  fi
  if modinfo apple_dma >/dev/null 2>&1 || modinfo vegpu_guest_dma >/dev/null 2>&1; then driver_installed="yes"; fi
  if lsmod | awk '{print $1}' | grep -qxE 'apple_dma|vegpu_guest_dma'; then module_loaded="yes"; fi
  if [ -f "$STATE_DIR/driver-persistent" ] ||
     grep -qxF apple_dma /etc/modules-load.d/apple-dma-load.conf 2>/dev/null; then driver_persistent="yes"; fi
  for dev in /sys/bus/pci/devices/*; do
    [ -e "$dev/vendor" ] || continue
    if [ "$(cat "$dev/vendor" 2>/dev/null || true)" = "0x1b36" ] &&
       [ "$(cat "$dev/device" 2>/dev/null || true)" = "0x0015" ]; then
      dma_device_present="yes"
      break
    fi
  done
  for dev in /sys/bus/pci/drivers/apple_dma/*:* /sys/bus/pci/drivers/vegpu_guest_dma/*:*; do
    [ -e "$dev" ] || continue
    bound_count=$((bound_count + 1))
    bound_devices="$bound_devices $(basename "$dev")"
  done
  bound_devices="$(printf '%s' "$bound_devices" | xargs 2>/dev/null || true)"
  driver_error="$(dmesg 2>/dev/null | grep -iE 'apple_dma .*managed PCI device .*not found|apple_dma .*unsupported version|apple_dma .*max_entries=0|apple_dma .*failed|apple_dma .*fatal' | tail -1 || true)"
  if [ "$module_loaded" = "yes" ] && [ "$kernel_match" != "no" ]; then driver_ready="yes"; fi
  if [ "$module_loaded" = "yes" ] && [ "$bound_count" -gt 0 ]; then passthrough_ready="yes"; fi
  jq -n     --arg user vegpu     --arg kernel "$(uname -r)"     --arg manifest "$manifest_id"     --arg expectedKernel "$expected_kernel"     --arg kernelMatchesManifest "$kernel_match"     --arg driver "$(dkms status 2>/dev/null | tr '\n' ';' || true)"     --arg driverInstalled "$driver_installed"     --arg driverPersistent "$driver_persistent"     --arg moduleLoaded "$module_loaded"     --arg driverLoaded "$module_loaded"     --arg driverReady "$driver_ready"     --arg passthroughReady "$passthrough_ready"     --arg dmaDevicePresent "$dma_device_present"     --arg boundDevices "$bound_devices"     --arg driverError "$driver_error"     --argjson boundDeviceCount "$bound_count"     --arg reboot "$([ -f "$STATE_DIR/reboot-required" ] && printf yes || printf no)"     '{user:$user,kernel:$kernel,manifest:$manifest,expectedKernel:$expectedKernel,kernelMatchesManifest:$kernelMatchesManifest,dkms:$driver,driverInstalled:$driverInstalled,driverPersistent:$driverPersistent,moduleLoaded:$moduleLoaded,driverLoaded:$driverLoaded,driverReady:$driverReady,passthroughReady:$passthroughReady,dmaDevicePresent:$dmaDevicePresent,boundDeviceCount:$boundDeviceCount,boundDevices:$boundDevices,driverError:$driverError,rebootRequired:$reboot}'
}

case "${1:-status}" in
  status)
    if [ "${2:-}" = "--json" ]; then status_json; else status_json; fi
    ;;
  apply-kernel-pin)
    apply_kernel_pin
    ;;
  ingest-manifest)
    shift
    ingest_manifest "$@"
    ;;
  ingest-package)
    shift
    ingest_package "$@"
    ;;
  ingest-seed-bundle)
    ingest_seed_bundle
    ;;
  update-agent)
    shift
    update_agent "$@"
    ;;
  update-tools)
    update_tools
    ;;
  disable-idle)
    disable_idle
    ;;
  install-driver|reinstall-driver)
    install_driver
    ;;
  setup-dkms-autorebuild)
    setup_dkms_autorebuild
    ;;
  dkms-refresh)
    dkms_refresh
    ;;
  configure-nvidia-repos)
    configure_nvidia_repos
    ;;
  install-nvidia-stack)
    install_nvidia_stack
    ;;
  configure-private-network)
    configure_private_network
    ;;
  configure-audio-rtp)
    shift
    configure_audio_rtp "$@"
    ;;
  ensure-ml-cache-policy)
    ensure_ml_cache_policy
    ;;
  export-linux-home-nfs)
    export_linux_home_nfs
    ;;
  apply-private-network)
    apply_private_network
    ;;
  apply-private-port)
    shift
    apply_private_port "$1" "${2:-tcp}"
    ;;
  update-kernel|reinstall-kernel)
    update_kernel
    ;;
  poweroff)
    systemctl poweroff
    ;;
  reboot)
    systemctl reboot
    ;;
  mount-nfs-share)
    shift
    mount_nfs_share "$@"
    ;;
  unmount)
    shift
    umount "$1" 2>/dev/null || true
    rmdir "$1" 2>/dev/null || true
    ;;
  *)
    log "unknown command: ${1:-}"
    exit 2
    ;;
esac

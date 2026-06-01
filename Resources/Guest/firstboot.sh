#!/usr/bin/env bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

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
      printf '[firstboot] apt lock busy; waiting for current package operation (%s/120)\n' "$attempt" >&2
      sleep 5
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$code"
  done
  printf '%s\n' "$output" >&2
  return "$code"
}

apt_get update
apt_get install -y openssh-server ca-certificates curl jq gnupg iptables nfs-common nfs-kernel-server rpcbind kmod sudo tmux
apt_get install -y dkms build-essential linux-headers-arm64 || true
apt_get install -y "linux-headers-$(uname -r)" || true

mkdir -p /run/vegpu/shares /var/lib/vegpu /usr/local/libexec/vegpu

cat >/etc/sudoers.d/90-vegpu-control <<'EOS'
vegpuctl ALL=(root) NOPASSWD:ALL
EOS
chmod 0440 /etc/sudoers.d/90-vegpu-control

/usr/local/libexec/vegpu/vegpu-agent apply-kernel-pin
/usr/local/libexec/vegpu/vegpu-agent setup-dkms-autorebuild
/usr/local/libexec/vegpu/vegpu-agent ensure-ml-cache-policy
/usr/local/libexec/vegpu/vegpu-agent ingest-seed-bundle || true
systemctl enable ssh
/usr/local/libexec/vegpu/vegpu-agent configure-private-network
/usr/local/libexec/vegpu/vegpu-agent configure-audio-rtp || true
usermod -aG dialout vegpu || true
usermod -aG dialout vegpuctl || true
/usr/local/libexec/vegpu/vegpu-agent configure-nvidia-repos
/usr/local/libexec/vegpu/vegpu-agent export-linux-home-nfs || true
systemctl restart ssh
/usr/local/libexec/vegpu/vegpu-agent update-tools || true
/usr/local/libexec/vegpu/vegpu-agent install-driver || true
/usr/local/libexec/vegpu/vegpu-agent status --json >/var/lib/vegpu/firstboot-status.json || true

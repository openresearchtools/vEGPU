#!/usr/bin/env bash
set -Eeuxo pipefail
export DEBIAN_FRONTEND=noninteractive
FIRSTBOOT_LOG=/var/log/pegpu-firstboot.log
mkdir -p /var/log
exec > >(tee -a "$FIRSTBOOT_LOG") 2>&1
trap 'code=$?; printf "[firstboot] failed at line %s: %s (exit %s)\n" "$LINENO" "$BASH_COMMAND" "$code" >&2' ERR

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

mkdir -p /run/pegpu/shares /var/lib/pegpu /usr/local/libexec/pegpu
/usr/local/libexec/pegpu/pegpu-agent disable-idle || true

apt_get update
apt_get install -y openssh-server ca-certificates curl jq gnupg iptables nfs-common nfs-kernel-server rpcbind kmod sudo tmux cloud-guest-utils e2fsprogs util-linux

mkdir -p /run/pegpu/shares /var/lib/pegpu /usr/local/libexec/pegpu

/usr/local/libexec/pegpu/pegpu-agent grow-root-filesystem || true
/usr/local/libexec/pegpu/pegpu-agent ingest-seed-bundle || true
/usr/local/libexec/pegpu/pegpu-agent apply-kernel-policy

mkdir -p /run/pegpu/shares /var/lib/pegpu /usr/local/libexec/pegpu

cat >/etc/sudoers.d/90-pegpu-control <<'EOS'
pegpuctl ALL=(root) NOPASSWD:ALL
EOS
chmod 0440 /etc/sudoers.d/90-pegpu-control

/usr/local/libexec/pegpu/pegpu-agent setup-dkms-autorebuild
/usr/local/libexec/pegpu/pegpu-agent ensure-ml-cache-policy
systemctl enable ssh
/usr/local/libexec/pegpu/pegpu-agent configure-private-network
/usr/local/libexec/pegpu/pegpu-agent configure-audio-rtp || true
usermod -aG dialout pegpu || true
usermod -aG dialout pegpuctl || true
/usr/local/libexec/pegpu/pegpu-agent prepare-nvidia-repos || true
/usr/local/libexec/pegpu/pegpu-agent export-linux-home-nfs || true
systemctl restart ssh
/usr/local/libexec/pegpu/pegpu-agent update-tools || true
/usr/local/libexec/pegpu/pegpu-agent install-driver
/usr/local/libexec/pegpu/pegpu-agent status --json >/var/lib/pegpu/firstboot-status.json || true

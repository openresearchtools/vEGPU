# vEGPU Guest VM Installation Notices

This notice describes software that vEGPU installs, configures, or asks Debian
APT to install inside the Linux guest VM.

It is intentionally scoped to the guest VM. It is not the license notice for
`vEGPU.app` itself, and it is not the license notice for `vEGPU Machine.app`.
Those notices remain in their own app legal bundles. This file is meant to make
the guest-side install activity visible to users.

## Debian Base Image

vEGPU downloads an official Debian cloud image for the runtime VM and verifies
the image checksum recorded in the runtime manifest. vEGPU does not ship a
modified Debian disk image in this repository.

The default runtime manifest currently points at Debian's official cloud image
service:

```text
https://cloud.debian.org/images/cloud/trixie/
```

Packages installed with `apt-get` come from the Debian repositories configured
inside that VM unless another repository is explicitly listed below. Debian
packages carry their own package metadata and license/copyright files inside
the VM, usually under `/usr/share/doc/<package>/copyright`.

The VM inherits its Debian APT source configuration from the downloaded Debian
cloud image. Debian package downloads normally resolve through Debian repository
services such as:

```text
https://deb.debian.org/debian
https://security.debian.org/debian-security
```

APT may install additional transitive dependencies selected by Debian at install
time. The lists below name the direct packages requested by vEGPU scripts.

## First Boot and Runtime Control Packages

On first boot, vEGPU installs the guest control-plane and sharing packages
needed for SSH, private networking, NFS sharing, kernel module management, and
guest repair commands:

- `openssh-server`
- `ca-certificates`
- `curl`
- `jq`
- `gnupg`
- `iptables`
- `nfs-common`
- `nfs-kernel-server`
- `rpcbind`
- `kmod`
- `sudo`
- `tmux`

When installing or refreshing the guest DMA driver, vEGPU also installs build
support for DKMS modules:

- `dkms`
- `build-essential`
- `kmod`
- `linux-headers-$(uname -r)` for the running kernel

When the guest kernel is explicitly updated, vEGPU requests:

- `linux-image-arm64`
- `linux-headers-arm64`

## GUI Desktop Packages

When the VM is started in GUI mode, vEGPU runs the guest GUI ensure script. That
script installs the XFCE, SPICE, Xorg, audio, browser, file manager, icon/theme,
and supporting packages needed for the embedded desktop experience:

- `dbus-x11`
- `lightdm`
- `lightdm-gtk-greeter`
- `gvfs-backends`
- `gvfs-fuse`
- `librsvg2-common`
- `mesa-utils`
- `libgl1-mesa-dri`
- `qemu-guest-agent`
- `spice-vdagent`
- `network-manager`
- `pipewire`
- `pipewire-pulse`
- `pipewire-alsa`
- `wireplumber`
- `jq`
- `gir1.2-gtk-3.0`
- `python3`
- `python3-gi`
- `firefox-esr`
- `thunar`
- `xdg-utils`
- `x11-xserver-utils`
- `xauth`
- `xinput`
- `xserver-xorg-core`
- `xserver-xorg-input-libinput`
- `xfce4-panel`
- `xfce4-power-manager`
- `xfce4-session`
- `xfce4-terminal`
- `xfconf`
- `xfdesktop4`
- `xfwm4`
- `adwaita-icon-theme`
- `greybird-gtk-theme`

These packages are installed from Debian APT repositories and are not bundled by
vEGPU. Their notices, licenses, and package metadata remain in the guest VM's
Debian package database and documentation directories.

## vEGPU Scaling Helper

vEGPU may install the local `vegpu-scaling` helper inside the VM. This is
vEGPU-owned MIT-licensed code used to adjust XFCE session scaling and expose a
small GTK scaling app.

When installed from the generated Debian package, `vegpu-scaling` declares these
Debian package dependencies instead of bundling them:

- `python3`
- `python3-gi`
- `gir1.2-gtk-3.0`
- `libglib2.0-bin`
- `xfconf`
- `x11-xserver-utils`

The package installs its own copyright file at:

```text
/usr/share/doc/vegpu-scaling/copyright
```

## Guest DMA Driver Package

vEGPU Machine supplies the guest DMA driver package that is installed inside the
VM. Current guest scripts look for Machine-provided packages named like:

- `apple-dma-dkms_*.deb`
- `vegpu-guest-dma-dkms_*.deb`

The package builds and installs the guest DMA kernel module through DKMS for the
VM kernel. vEGPU may install Debian DKMS/build/header packages listed above so
the module can build against the running guest kernel.

The DMA driver package is a vEGPU Machine guest artifact, not a Debian package
downloaded from APT and not an app-side vEGPU notice. vEGPU Machine carries its
own notices, licenses, and source bundles for Machine-side and guest-driver
artifacts.

## NVIDIA Repository Preparation

During current first-boot setup, the guest agent prepares NVIDIA's Debian 13
SBSA CUDA repository so NVIDIA driver and CUDA packages can be resolved later
by APT. The actual NVIDIA driver and CUDA toolkit package installation remains
optional. Repository preparation uses NVIDIA's repository metadata and keyring
package from:

```text
https://developer.download.nvidia.com/compute/cuda/repos/debian13/sbsa
https://developer.download.nvidia.com/compute/cuda/repos/debian13/sbsa/cuda-keyring_1.1-1_all.deb
```

Repository setup may install these Debian packages first:

- `ca-certificates`
- `curl`
- `gnupg`

It also writes guest configuration files such as:

- `/etc/modprobe.d/blacklist-nouveau.conf`
- `/etc/apt/preferences.d/vegpu-nvidia-pin`
- `/etc/apt/sources.list.d/cuda-debian13-sbsa.list`

vEGPU does not bundle NVIDIA driver or CUDA toolkit packages in this repository.
When those packages are installed, they are downloaded by APT from NVIDIA's
repository inside the VM.

## Optional NVIDIA Driver and CUDA Installation

If the user chooses to run vEGPU's NVIDIA/CUDA installer, the guest agent runs
APT inside the VM to install the currently pinned NVIDIA stack:

```text
apt-get install -y --allow-downgrades \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold \
  nvidia-driver-pinning-595.71.05 \
  nvidia-open=595.71.05-1 \
  cuda-toolkit-13-2=13.2.1-1
```

The installer may remove `xserver-xorg-video-nouveau` if it is present, and it
attempts to load the `nvidia` and `nvidia_uvm` kernel modules after
installation.

By choosing to install NVIDIA driver and CUDA support, the user is choosing to
download and install NVIDIA-provided software from NVIDIA's repository inside
the VM. The user should review and accept the applicable NVIDIA terms before
using that software, including the CUDA Toolkit EULA and any NVIDIA driver or
repository terms applicable to the packages installed:

- NVIDIA CUDA Toolkit EULA: https://docs.nvidia.com/cuda/eula/index.html
- NVIDIA CUDA Linux installation guide: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
- NVIDIA driver installation guide for Debian: https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/595/debian.html

## Inspecting the Guest

Users can inspect what was actually installed in a running VM with commands such
as:

```sh
apt list --installed
dpkg-query -W
apt-cache policy nvidia-open cuda-toolkit-13-2 vegpu-scaling
ls /etc/apt/sources.list.d/
ls /etc/apt/preferences.d/
find /usr/share/doc -maxdepth 2 -name copyright
```

The exact installed package set can vary by Debian repository state, transitive
dependencies, runtime manifest version, selected VM mode, and whether the user
chooses optional NVIDIA/CUDA installation.

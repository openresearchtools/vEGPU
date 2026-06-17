# PEGPU App Architecture

This repository builds `PEGPU.app`, the Swift/AppKit application. The separate
`PEGPU Machine.app` repository owns QEMU, firmware, VFIO DriverKit code, Linux
guest DMA packages, and Machine-side source bundles.

The app boundary is process and package separation:

- `PEGPU.app` owns the native macOS UI, runtime orchestration, SPICE display
  client, SSH control plane, NFS share setup, metrics, and llama.cpp-compatible
  model routing UI.
- `PEGPU Machine.app` owns the patched QEMU launcher, macOS DriverKit dext,
  firmware, guest DMA/DKMS packages, and Machine notices/source bundles.
- `PEGPU.app` starts Machine through the supported Machine app entrypoints; it
  does not vendor QEMU or construct private QEMU internals as release payload.
- App-side SPICE/CocoaSpice/ANGLE display dependencies are built from the
  pinned UTM dependency recipe during CI and bundled as app frameworks.

The normal network shape is fixed:

```text
macOS app/control plane <-> vmnet-shared <-> Debian guest

host gateway: 172.29.253.1
guest:        172.29.253.100
guest MAC:    de:ad:be:ef:10:01
```

SSH is a private control plane used for guest-agent commands, package sync,
health checks, terminal access, and repair. Application traffic such as web UI,
llama.cpp server APIs, and RPC endpoints uses raw TCP over vmnet instead of SSH
tunnels.

## Display Runtime

The app has two display layers with different ownership:

- Embedded SPICE display: app-side CocoaSpice renders the guest's virtio/SPICE
  desktop inside the macOS app window.
- External GPU desktops: guest-side Xorg/NVIDIA sessions own physical displays
  connected to passed-through GPUs. Those displays are not SPICE monitors and
  are not rendered by the app.

The app-side display frameworks come from:

```text
$RUNNER_TEMP/pegpu-artifacts/display-frameworks/macos-arm64
```

That directory is generated during CI from the pinned UTM/WebKit/ANGLE source
recipes, uploaded in this branch as
`PEGPU-display-frameworks-legacy-macos13_5-arm64`, and is not written into the
checkout.

## Runtime Image

PEGPU downloads the official Debian cloud image and keeps mutable VM state under
`~/Library/Application Support/PEGPU/Machine`. The app does not ship a modified
Debian disk image.

The cloud-init seed carries user setup, SSH keys, guest scripts, the scaling
helper package when available, and a guest-tools manifest resolved from
`PEGPU Machine.app`. First boot ingests the seed bundle and installs the guest
DMA driver; later app launches can repair or refresh guest state over SSH.

## Guest Packages

Guest DMA/DKMS packages are Machine artifacts, not app artifacts. The combined
installer bundles them inside `PEGPU Machine.app` and also bundles Machine
source tarballs next to Machine resources for release compliance.

The app-side Linux desktop helpers are different: they are small PEGPU-owned
Python and desktop integration code under `Resources/Guest/scaling-app` and
`Resources/Guest/performance-app`. CI packages the scaling helper as
`pegpu-scaling_*.deb` in a disposable Debian build container and bundles that
package into `PEGPU.app`; cloud-init/SSH install the performance helper from the
bundled source tree. The performance helper presents PEGPU DMA coalescing
presets and delegates persistence to the Machine-supplied `apple-dma-config`
tool from the `apple-dma-dkms` guest package.

## Model Routing

The app includes a Go router and web UI under `ai/web-ui-app`. Runtime binaries
such as `llama-server`, `rpc-server`, and llama.cpp dylibs are not committed to
this source repository. Release packages can bundle managed macOS/Linux
llama.cpp runtime archives under the app bootstrap runtime directory; additional
runtime pairs remain user-managed through the Core UI. Bundled runtime archives
are covered by the app-visible distribution `LICENSES` file, while source
archives installed under `legal/generated/source/` have adjacent legal sidecars
for their archive contents.

Mutable router config lives in app data:

```text
~/Library/Application Support/PEGPU/Machine/ai/llms/app.yaml
```

The repository's `ai/web-ui-app/app.yaml` is only a sanitized default/example,
with no user-local model paths.

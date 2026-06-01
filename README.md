# vEGPU

vEGPU is an experimental macOS application for running NVIDIA Thunderbolt eGPUs
through a Linux VM on Apple Silicon Macs. It is built as two related
applications with an explicit license and architecture boundary.

## Applications

- **vEGPU.app** is the Swift/AppKit launcher, embedded SPICE display client,
  AI/runtime router, file/port/terminal UI, and host-side orchestration layer.
- **vEGPU Machine.app** is the separate QEMU/VFIO/DriverKit runtime
  application. It owns the patched QEMU launcher, macOS DriverKit host
  extension, firmware/runtime payloads, Linux guest-driver packages, and its
  own notices/source bundles.

The combined installer may install both apps into `/Applications`, but the
repositories, notices, source archives, and runtime responsibilities stay
separate.

## License And Source Boundary

vEGPU.app is distributed under the permissive Apache License, Version 2.0.
Like UTM, it bundles components under other licenses. The app-side display
runtime includes SPICE, GLib, GStreamer, ANGLE, CocoaSpice/UTM-derived display
work, and related support libraries. Release packages carry notices and
corresponding source/provenance archives inside:

```text
/Applications/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated
```

vEGPU Machine.app is distributed from
[openresearchtools/vEGPU-machine](https://github.com/openresearchtools/vEGPU-machine).
It contains the QEMU/VFIO/DriverKit side and carries its own notices and source
bundles inside:

```text
/Applications/vEGPU Machine.app/Contents/Resources
```

vEGPU Machine builds on Scott J. Goldman's
[scottjg/qemu-vfio-apple](https://github.com/scottjg/qemu-vfio-apple), and also
uses/adapts UTM/QEMU-side work from
[utmapp/qemu](https://github.com/utmapp/qemu) and
[utmapp/virglrenderer](https://github.com/utmapp/virglrenderer). The app-side
display integration is generated from a pinned
[utmapp/UTM](https://github.com/utmapp/UTM) base plus the patch stack in
`third_party/utm/patches`.

GPL-covered QEMU-derived code stays on the Machine side. Apache-side
launcher/display/AI code stays in this repository. File-level and component
license notices remain authoritative.

## Installer

The release package installs vEGPU.app and, when needed, vEGPU Machine.app.
The Installation Type screen shows the Machine/DriverKit component separately.
If the installed Machine app is the same version or newer, that component is
visible but not selected by default.

When the Machine component is selected and the package carries a newer Machine
build, the installer tries to deactivate the old macOS DriverKit extension,
falls back to `systemextensionsctl uninstall` if needed, replaces vEGPU
Machine.app, submits a fresh activation request, and asks macOS to offer the
normal Restart Now / Later choice.

System Integrity Protection must be disabled before installation. vEGPU uses an
ad-hoc DriverKit host extension for PCIe/eGPU passthrough, which is a serious
security tradeoff.

## Build

GitHub Actions is the release build path. The workflow can build artifact-only
packages, pre-releases, or releases while reusing cached display runtime,
scaling helper, and Machine artifacts when their inputs have not changed.

The clean repository intentionally does not commit generated display
frameworks, QEMU/Machine binaries, runtime downloads, model files, or VM disk
images.

## Links

- Website: [vegpu.com](https://vegpu.com)
- vEGPU app repository: [openresearchtools/vEGPU](https://github.com/openresearchtools/vEGPU)
- vEGPU Machine repository: [openresearchtools/vEGPU-machine](https://github.com/openresearchtools/vEGPU-machine)
- Upstream breakthrough: [scottjg/qemu-vfio-apple](https://github.com/scottjg/qemu-vfio-apple)

vEGPU is not endorsed by, sponsored by, or affiliated with Apple, NVIDIA, QEMU,
UTM, Scott J. Goldman, or their maintainers.

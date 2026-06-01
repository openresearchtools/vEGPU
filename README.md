# vEGPU

vEGPU is an experimental macOS application for running NVIDIA Thunderbolt eGPUs
through a Linux VM on Apple Silicon Macs. It is built as two related
applications with an explicit license and architecture boundary.

## Applications

- **vEGPU.app** is the Swift/AppKit launcher, UTM-derived embedded SPICE GUI
  display side, ANGLE/CocoaSpice integration, AI/runtime router,
  file/port/terminal UI, sidecar metrics, and host-side orchestration layer.
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
runtime includes SPICE, GLib, GStreamer, ANGLE, CocoaSpice, UTM-derived GUI
display work, and related support libraries. Release packages carry notices and
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
embedded GUI display integration is partially based on the main
[utmapp/UTM](https://github.com/utmapp/UTM) app work and is generated from a
pinned UTM base plus the vEGPU patch stack in `third_party/utm/patches`.

GPL-covered QEMU-derived code stays on the Machine side. Apache-side
launcher/display/AI code stays in this repository. File-level and component
license notices remain authoritative.

## Runtime And Routing Provenance

vEGPU is not a single upstream project with a new skin. It combines several
separate pieces, with notices and source/provenance kept in the app bundles:

- **UTM app display work**:
  [utmapp/UTM](https://github.com/utmapp/UTM) is the main GUI foundation for
  the embedded SPICE display side. vEGPU carries its UTM/CocoaSpice app-side
  changes as patches, then CI applies them to the pinned UTM base and builds
  the SPICE/GLib/GStreamer/ANGLE frameworks from source. vEGPU does not bundle
  UTM.app as an app.
- **QEMU/VFIO Machine runtime**:
  [scottjg/qemu-vfio-apple](https://github.com/scottjg/qemu-vfio-apple),
  [utmapp/qemu](https://github.com/utmapp/qemu), and
  [utmapp/virglrenderer](https://github.com/utmapp/virglrenderer) are part of
  the separate vEGPU Machine side, along with QEMU-derived GPL-covered source
  bundles and guest-driver packages.
- **llama.cpp chat/runtime surface**:
  [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) provides the
  server conventions, OpenAI/llama.cpp-compatible APIs, web UI surface, and
  runtime shape that vEGPU adapts for app-managed model discovery, downloads,
  runtime launches, macOS/VM runtime pairs, and external GPU offload choices.
- **llama-swap-style model routing**:
  [mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap) is the
  basis for the routing idea. vEGPU modifies that model so multiple aliases and
  sessions can route through configured macOS and VM runtimes rather than a
  single fixed `llama-server` process.
- **GOST-style local networking**:
  [ginuerzh/gost](https://github.com/ginuerzh/gost) is the provenance for the
  localhost TCP/UDP forwarding model. vEGPU keeps a trimmed local proxy for
  Mac-to-VM and VM-to-Mac routing; it is limited to the forwarding behavior the
  app needs.
- **TurboQuant runtime option**:
  [TheTom/llama-cpp-turboquant](https://github.com/TheTom/llama-cpp-turboquant)
  is supported as an optional llama.cpp-family runtime source for Turbo KV cache
  quantization builds.

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
- UTM app foundation: [utmapp/UTM](https://github.com/utmapp/UTM)
- AI runtime: [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)
- Routing provenance: [mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap)
- Local proxy provenance: [ginuerzh/gost](https://github.com/ginuerzh/gost)

vEGPU is not endorsed by, sponsored by, or affiliated with Apple, NVIDIA, QEMU,
UTM, llama.cpp, llama-swap, GOST, Scott J. Goldman, or their maintainers.

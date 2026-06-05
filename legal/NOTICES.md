# vEGPU Notices

vEGPU is the app-side Swift/AppKit runtime manager, UTM-derived embedded SPICE
GUI display client, ANGLE/CocoaSpice integration, model routing interface,
sidecar networking, and macOS orchestration layer. vEGPU Machine is a separate
app/repository for QEMU, VFIO, DriverKit, firmware, guest driver packages, and
their GPL/source bundles.

## License Boundary

vEGPU.app is distributed under the permissive Apache License, Version 2.0.
Like UTM, the app bundles and loads components with their own licenses,
including SPICE/GLib/GStreamer/ANGLE, CocoaSpice, UTM-derived GUI display
work, and related support libraries. The installed app carries generated
notices plus corresponding app/display-runtime source archives under
`Contents/Resources/vEGPURoot/legal/generated`.

vEGPU Machine.app is distributed as the separate Machine/runtime application.
It carries the QEMU/VFIO/DriverKit side, including QEMU-derived GPL-covered
source, guest-driver packages, firmware/runtime support, and Machine-side
notices/source bundles. GPL-derived QEMU code stays on the Machine side; the
Apache-side vEGPU launcher/display/AI code stays separate.

The combined installer may place both applications in `/Applications`, but the
installed apps, repositories, notices, and source archives keep this boundary
visible.

For convenience, vEGPU.app Help can render external vEGPU Machine notices and
licenses from the installed vEGPU Machine.app. The Help menu marks those
Machine-owned rows as EXTERNAL. vEGPU.app does not copy Machine legal text into
its own bundle.
Those external files remain owned by vEGPU Machine.app:

- `/Applications/vEGPU Machine.app/Contents/Resources/ThirdPartyNotices/NOTICES`
- `/Applications/vEGPU Machine.app/Contents/Resources/ThirdPartyNotices/LICENSES`

## Guest VM Installation Notice

`legal/GUEST-VM-INSTALL-NOTICES.md` documents software that vEGPU installs
inside the Linux guest VM through Debian APT, local vEGPU/vEGPU Machine guest
packages, GUI desktop setup, and optional NVIDIA/CUDA repository packages. It
is intentionally separate from the app-side and Machine-side legal notices.
Release builds install it as `GUEST-VM-INSTALL-NOTICES.md` in the generated
legal folder so the Help menu can open it directly.

## UTM Patch Stack Display Work

The committed repository does not carry a copied UTM source tree.
The app-side embedded GUI display integration is partially based on the main
UTM app work:

  https://github.com/utmapp/UTM

vEGPU carries UTM/CocoaSpice modifications as patches under:

  third_party/utm/patches/

Release and CI builds clone the pinned UTM base, apply those patches, and then
build the app-side SPICE/GLib/GStreamer/ANGLE runtime from source.

Base recipe:

- UTM repository: https://github.com/utmapp/UTM.git
- UTM commit: e4a4c34b671284263fc69f81b607de494d7e9b65

## llama-swap-Derived Routing

The AI web UI routing service includes request-routing behavior based on
llama-swap:

  https://github.com/mostlygeek/llama-swap

vEGPU modifies that routing model to route llama.cpp-compatible API requests
across configured macOS and VM runtimes, including multiple model entries served
from the same runtime instance and sessions detached from a single fixed
`llama-server` process.

The llama-swap MIT license is kept in `legal/LICENSES/llama-swap-MIT.txt`.
Directory-specific provenance is kept in `ai/web-ui-app/NOTICE`.

## llama.cpp Web UI and Runtime Integration

The embedded chat UI and runtime controls are based on llama.cpp server
conventions, llama.cpp-compatible APIs, and the llama.cpp web UI surface,
modified for vEGPU to support multiple models, runtime pairs, VM/macOS routing,
and external GPU offload choices.

Upstream:

  https://github.com/ggml-org/llama.cpp

vEGPU does not store llama.cpp runtime binaries in this source repository.
Release packages bundle the latest llama.cpp ARM64 runtime build available at
vEGPU release time from openresearchtools/llama-cpp-arm64-builds. Additional
llama.cpp and TurboQuant runtime versions remain user-managed through /core.
Runtime artifacts carry their own license files. The vEGPU app source bundle
includes the modified web UI/static sources used by the app.

The llama.cpp MIT license is kept in `legal/LICENSES/llama.cpp-MIT.txt`.
Directory-specific provenance is kept in `ai/web-ui-app/NOTICE`.

## TurboQuant Runtime Option

vEGPU can route to llama.cpp-family runtime builds based on Tom's TurboQuant
fork when the user installs/activates those runtime artifacts.

Upstream:

  https://github.com/TheTom/llama-cpp-turboquant

## vEGPU Linux Scaling Helper

The Linux scaling helper under `Resources/Guest/scaling-app` is original
OpenResearchTools/vEGPU code distributed under the MIT license. CI packages it as
`vegpu-scaling_*.deb` in a disposable Debian container. The package installs a
Debian copyright file and depends on system Python, GTK/PyGObject, X11, and
XFCE tools rather than bundling those dependencies.

## GOST-Derived Local Proxy

The local proxy helper in `ai/gost-local-proxy` is based on GOST's forwarding
model for localhost TCP/UDP forwarding between macOS and the VM:

  https://github.com/ginuerzh/gost

It is kept under the MIT license. Its license and notice are kept in that
directory and collected into generated release notices.

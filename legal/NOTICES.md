# vEGPU Notices

vEGPU is the app-side Swift/AppKit runtime manager, SPICE client UI, and model
routing interface. vEGPU Machine is a separate app/repository for QEMU, VFIO,
DriverKit, firmware, guest driver packages, and their GPL/source bundles.

## License Boundary

vEGPU.app is distributed under the permissive Apache License, Version 2.0.
Like UTM, the app bundles and loads components with their own licenses,
including SPICE/GLib/GStreamer/ANGLE and related support libraries. The
installed app carries generated notices plus corresponding app/display-runtime
source archives under `Contents/Resources/vEGPURoot/legal/generated`.

vEGPU Machine.app is distributed as the separate Machine/runtime application.
It carries the QEMU/VFIO/DriverKit side, including QEMU-derived GPL-covered
source, guest-driver packages, firmware/runtime support, and Machine-side
notices/source bundles. GPL-derived QEMU code stays on the Machine side; the
Apache-side vEGPU launcher/display/AI code stays separate.

The combined installer may place both applications in `/Applications`, but the
installed apps, repositories, notices, and source archives keep this boundary
visible.

## UTM Patch Stack Display Work

The committed repository does not carry a copied UTM source tree.
vEGPU carries UTM/CocoaSpice modifications as patches under:

  third_party/utm/patches/

Release and CI builds clone the pinned UTM base, apply those patches, and then
build the app-side SPICE/GLib/GStreamer/ANGLE runtime from source.

Base recipe:

- UTM repository: https://github.com/utmapp/UTM.git
- UTM commit: e4a4c34b671284263fc69f81b607de494d7e9b65

## llama-swap-Derived Routing

The AI web UI routing service includes request-routing behavior based on
llama-swap. vEGPU modifies that routing model to route llama.cpp-compatible API
requests across configured macOS and VM runtimes, including multiple model
entries served from the same runtime instance and sessions detached from a
single fixed `llama-server` process.

The llama-swap MIT license is kept in `legal/LICENSES/llama-swap-MIT.txt`.
Directory-specific provenance is kept in `ai/web-ui-app/NOTICE`.

## llama.cpp Web UI and Runtime Integration

The embedded chat UI and runtime controls are based on llama.cpp server
conventions, llama.cpp-compatible APIs, and the llama.cpp web UI surface,
modified for vEGPU to support multiple models, runtime pairs, VM/macOS routing,
and external GPU offload choices.

vEGPU does not store llama.cpp runtime binaries in this source repository.
Runtime artifacts are obtained through configured runtime release channels and
carry their own license files. The vEGPU app source bundle includes the
modified web UI/static sources used by the app.

The llama.cpp MIT license is kept in `legal/LICENSES/llama.cpp-MIT.txt`.
Directory-specific provenance is kept in `ai/web-ui-app/NOTICE`.

## vEGPU Linux Scaling Helper

The Linux scaling helper under `Resources/Guest/scaling-app` is original
OpenResearchTools/vEGPU code distributed under the MIT license. CI packages it as
`vegpu-scaling_*.deb` in a disposable Debian container. The package installs a
Debian copyright file and depends on system Python, GTK/PyGObject, X11, and
XFCE tools rather than bundling those dependencies.

## GOST-Derived Local Proxy

The local proxy helper in `ai/gost-local-proxy` is based on GOST's forwarding
model and is kept under the MIT license. Its license and notice are kept in
that directory and collected into generated release notices.

# vEGPU Notices

vEGPU is the app-side Swift/AppKit runtime manager, SPICE client UI, and model
routing interface. vEGPU Machine is a separate app/repository for QEMU, VFIO,
DriverKit, firmware, guest driver packages, and their GPL/source bundles.

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
vEGPU code distributed under the MIT license. CI packages it as
`vegpu-scaling_*.deb` in a disposable Debian container. The package installs a
Debian copyright file and depends on system Python, GTK/PyGObject, X11, and
XFCE tools rather than bundling those dependencies.

## GOST-Derived Local Proxy

The local proxy helper in `ai/gost-local-proxy` is based on GOST's forwarding
model and is kept under the MIT license. Its license and notice are kept in
that directory and collected into generated release notices.

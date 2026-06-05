# vEGPU Legal Seed Files

This directory is not the complete release notice bundle.

It contains small, checked-in seed notices for vEGPU-owned or directly
modified app-side code. Release and CI builds generate the full installed legal
payload with `scripts/build-legal-bundle.sh`.

The generated payload also collects:

- the top-level vEGPU app license
- Swift package license/notice files from resolved checkouts
- Go module license/notice files from module caches
- ANGLE source/import/license records
- UTM/CocoaSpice patch provenance
- the display runtime corresponding source archive
- the separate vEGPU Machine notices/source bundle locations
- the guest VM installation notice for Debian APT, GUI, DMA driver, and
  optional NVIDIA/CUDA install activity

The generated output is installed under:

```text
vEGPU.app/Contents/Resources/vEGPURoot/legal/generated
```

The canonical generated app-side files are `NOTICES` and `LICENSES`.
`GUEST-VM-INSTALL-NOTICES.md` is generated as a separate user-facing file.
`NOTICES.md` is also generated as a compatibility copy for older tooling.

The vEGPU app Help menu opens those generated files. For convenience, it can
also render external vEGPU Machine notices and licenses from the installed
`vEGPU Machine.app`. The Help menu marks those Machine-owned rows as
`EXTERNAL`, and vEGPU.app does not copy Machine legal text into its own bundle.
vEGPU Machine carries its own QEMU/VFIO/DriverKit notices, licenses, and source
bundles inside `vEGPU Machine.app`.

`GUEST-VM-INSTALL-NOTICES.md` is the checked-in seed notice for software that
vEGPU installs inside the Linux VM from Debian APT, NVIDIA APT repositories, or
local vEGPU/vEGPU Machine guest packages. It is not a substitute for the app or
Machine legal bundles.

The generated legal files list the installed source archive locations for
vEGPU.app and vEGPU Machine.app so users do not have to inspect the installer
package by hand.

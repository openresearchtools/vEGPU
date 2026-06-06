# PEGPU Legal Seed Files

This directory is not the complete release notice bundle.

It contains small, checked-in seed notices for PEGPU-owned or directly
modified app-side code. Release and CI builds generate the full installed legal
payload with `scripts/build-legal-bundle.sh`.

The generated payload also collects:

- the top-level PEGPU app license
- Swift package license/notice files from resolved checkouts
- Go module license/notice files from module caches
- ANGLE source/import/license records
- UTM/CocoaSpice patch provenance
- the display runtime corresponding source archive
- the separate PEGPU Machine notices/source bundle locations
- the guest VM installation notice for Debian APT, GUI, DMA driver, and
  optional NVIDIA/CUDA install activity

The generated output is installed under:

```text
PEGPU.app/Contents/Resources/PEGPURoot/legal/generated
```

The canonical generated app-side files are `NOTICES` and `LICENSES`.
`GUEST-VM-INSTALL-NOTICES.md` is generated as a separate user-facing file.
`NOTICES.md` is also generated as a compatibility copy for older tooling.

`LICENSES` is the app-visible distribution license bundle for installed
PEGPU.app runtime payloads, helper programs, framework dependencies, and
app-managed runtime archives. Source archives under `source/` are accompanied by
adjacent generated `.NOTICES`, `.LICENSES`, and `.manifest.json` sidecars. Those
sidecars are the exhaustive legal records for the contents of each source
archive, including source-only build tools, tests, examples, backend source
trees, and provenance inputs used to reproduce app-side artifacts.

The PEGPU app Help menu opens those generated files. For convenience, it can
also render external PEGPU Machine notices and licenses from the installed
`PEGPU Machine.app`. The Help menu marks those Machine-owned rows as
`EXTERNAL`, and PEGPU.app does not copy Machine legal text into its own bundle.
PEGPU Machine carries its own QEMU/VFIO/DriverKit notices, licenses, and source
bundles inside `PEGPU Machine.app`.

`GUEST-VM-INSTALL-NOTICES.md` is the checked-in seed notice for software that
PEGPU installs inside the Linux VM from Debian APT, NVIDIA APT repositories, or
local PEGPU/PEGPU Machine guest packages. It is not a substitute for the app or
Machine legal bundles.

The generated legal files list the installed source archive locations and
source-archive sidecars for PEGPU.app and PEGPU Machine.app so users do not
have to inspect the installer package by hand.

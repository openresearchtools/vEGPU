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

The generated output is installed under:

```text
vEGPU.app/Contents/Resources/vEGPURoot/legal/generated
```

The canonical generated app-side files are `NOTICES` and `LICENSES`.
`NOTICES.md` is also generated as a compatibility copy for older tooling.

The vEGPU app Help menu opens those generated files. vEGPU Machine carries its
own QEMU/VFIO/DriverKit notices, licenses, and source bundles inside
`vEGPU Machine.app`.

The generated vEGPU Help window also exposes export buttons so users can copy
the bundled source archives to a normal folder without having to inspect the
installer package by hand.

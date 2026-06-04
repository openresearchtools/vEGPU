# vEGPU Release Repository Layout

This repo builds `vEGPU.app`, the Apache-side Swift/AppKit application. It does
not vendor QEMU, firmware, VFIO DriverKit code, or guest GPL source. Those live
in the separate `vEGPU Machine.app` build.

## Repositories

- `openresearchtools/vEGPU`: builds `vEGPU.app`.
- `openresearchtools/vEGPU-machine`: builds `vEGPU Machine.app`, QEMU/VFIO,
  firmware, guest tools, Machine notices, and Machine source bundles.

The public download can still be one `.pkg`. The package should install both
apps into `/Applications`, but the source trees and license payloads stay
separate.

## vEGPU App Build

Do not use raw `swift build` as a release build entrypoint. `Package.swift`
intentionally points at a generated CocoaSpice package path, and CI creates
that package from the pinned UTM source plus `third_party/utm/patches` before
SwiftPM runs. The supported build entrypoint is the bundle script below, and
the public release path is the GitHub Actions workflow.

```sh
CONFIGURATION=release scripts/build-app-bundle.sh
```

The bundle script writes generated dependencies and SwiftPM scratch data under
`$RUNNER_TEMP`/`$VEGPU_BUILD_ROOT`, not into the repository.

The app build generates current legal payloads under:

```text
$RUNNER_TEMP/vegpu-artifacts/legal/generated
$RUNNER_TEMP/vegpu-artifacts/app/vEGPU.app/Contents/Resources/vEGPURoot/legal/generated
```

The generated folder contains:

- `NOTICES`
- `LICENSES`
- `NOTICES.md` compatibility copy
- `manifest.json`
- copied app-side license inputs under `license-files/`
- `source/vEGPU-app-source.tar.gz`

Legacy `THIRD_PARTY_*` files are not copied into the app bundle.

## Strict Release Source Check

For public release builds, require the copied display-runtime corresponding
source archive:

```sh
VEGPU_REQUIRE_FULL_SOURCE=1 CONFIGURATION=release scripts/build-app-bundle.sh
```

That expects the display-runtime source artifact path from CI, normally:

```text
$RUNNER_TEMP/vegpu-input/display-runtime-source/display-runtime-source.tar.gz
```

This is deliberately strict: the current app bundles SPICE/GLib/GStreamer/etc
frameworks copied from the UTM display runtime, so the public release must carry
the matching source/provenance bundle instead of relying on stale legacy
notices.

## Source-Built Display Runtime

For a release build, generate the app-side display frameworks from the pinned
UTM dependency recipe:

```sh
VEGPU_UTM_REPO="https://github.com/<owner>/<utm-display-runtime-fork>.git" \
VEGPU_UTM_COMMIT="e4a4c34b671284263fc69f81b607de494d7e9b65" \
scripts/build-display-runtime-from-source.sh
```

This script uses UTM only as a dependency recipe source. It does not build
UTM.app and it does not build QEMU. It builds the SPICE client stack,
GLib/GStreamer/libsoup/libusb dependencies, and ANGLE frameworks needed by
`vEGPU.app`.

Outputs:

```text
$RUNNER_TEMP/vegpu-artifacts/display-frameworks/macos-arm64
$RUNNER_TEMP/vegpu-artifacts/display-runtime-source/display-runtime-source.tar.gz
```

## GitHub Actions

`.github/workflows/build.yml` supports three release modes:

- `artifact-only`: build source-backed display frameworks, build the Linux
  scaling helper package, build `vEGPU.app`, trigger/fetch `vEGPU Machine`
  artifacts, and upload the combined installer as a workflow artifact only.
- `pre-release`: does the same build, then creates or updates a prerelease with
  one asset: the combined `.pkg`.
- `full-release`: does the same build, then creates or updates a stable GitHub
  release with one asset: the combined `.pkg`.

Pre-release and full-release runs also update the matching app update manifest
in `releases/`. Artifact-only runs do not update either manifest.

Workflow inputs:

- `utm_repository` / `utm_commit`: select the UTM dependency recipe fork and
  commit.
- `machine_mode=download-run`: download artifacts from an existing Machine
  workflow run id.
- `machine_mode=trigger`: trigger the Machine workflow in `machine_repository`
  and wait for the app/source artifacts.
- `release_version` / `build_number`: written into `vEGPU.app`
  `CFBundleShortVersionString` and `CFBundleVersion`; when `machine_mode=trigger`
  the same values are passed to the Machine workflow so a newly built
  `vEGPU Machine.app` carries matching version metadata.
- `llama_runtime_tag`: selects the bundled llama.cpp runtime release from
  `openresearchtools/llama-cpp-arm64-builds`; `latest` resolves to the newest
  stable llama.cpp release and bundles macOS, Debian Trixie CUDA 13, and Debian
  Trixie Vulkan ARM64 archives.
- `publish_release=true`: manual override to publish a release from
  `artifact-only`; release assets still contain only the combined `.pkg`.

For cross-repo Machine triggering, set a repository secret named
`VEGPU_MACHINE_TOKEN` with permission to run and read workflow artifacts from
the Machine repository.

## Cache Policy

CI caches only generated outputs under GitHub runner cache/temp paths. It does
not write cached build products into the checkout.

- Display runtime: exact artifact cache keyed by UTM commit, display build
  scripts, normalization script, and vEGPU UTM patches. On a hit, the job skips
  Homebrew setup and the full SPICE/GLib/GStreamer/ANGLE rebuild.
- Display runtime work tree: secondary cache for downloaded/upstream build
  state, used only when the exact display artifact cache misses.
- Scaling package: exact package cache keyed by the scaling helper source and
  package script. On a hit, the Debian container build is skipped.
- vEGPU.app: exact app/legal payload cache keyed by Swift sources, resources,
  Go router sources, app build/legal scripts, display runtime inputs, scaling
  package inputs, docs, legal files, and UTM patches. On a hit, the app build is
  skipped and the restored app is still validated and uploaded.
- SwiftPM and patched UTM package worktree: incremental caches used only when
  `vEGPU.app` itself has to rebuild.

Machine/QEMU/DKMS artifacts are not guessed from this repo cache. The workflow
either downloads a specific Machine run or triggers the Machine workflow so the
Machine repository remains the source of truth for its own cache and rebuild
decisions.

## vEGPU Machine Notices

`vEGPU Machine.app` carries its own notices and source bundles inside that app,
for example:

```text
/Applications/vEGPU Machine.app/Contents/Resources/ThirdPartyNotices
/Applications/vEGPU Machine.app/Contents/Resources/guest-tools/source
```

`vEGPU.app` exposes Help menu items to open `vEGPU Machine.app` and reveal those
Machine notices. Do not duplicate Machine GPL source inside the Apache-side
vEGPU app unless the release package intentionally adds a top-level convenience
copy.

## One-Package Release Shape

A public `.pkg` should contain:

- `/Applications/vEGPU.app`
- `/Applications/vEGPU Machine.app`
- optional top-level release notes

Build it from an already built Machine app:

```sh
VEGPU_MACHINE_APP="/path/to/vEGPU Machine.app" \
VERSION=0.1.0 \
scripts/build-release-pkg.sh
```

The package license screen should mention that the install contains two apps
with separate notices:

- vEGPU app notices/licenses: `vEGPU.app/Contents/Resources/vEGPURoot/legal/generated/NOTICES`
  and `vEGPU.app/Contents/Resources/vEGPURoot/legal/generated/LICENSES`
- vEGPU Machine notices/source: `vEGPU Machine.app/Contents/Resources`

The app Help menu points users to both.

Package names are channel-specific:

- `vEGPU-v0.1.0-artifact.pkg` for artifact-only workflow runs.
- `vEGPU-v0.1.0-pre-release.pkg` for prereleases.
- `vEGPU-v0.1.0.pkg` for stable releases.

The package welcome/readme/license resources also state:

- `https://vegpu.com`
- `https://github.com/openresearchtools/vEGPU`
- `https://github.com/openresearchtools/vEGPU-machine`
- SIP must be disabled before installation; the package preinstall scripts
  refuse installation when `csrutil status` is not disabled and print the
  Apple Silicon recovery Terminal steps.
- Postinstall scripts clear quarantine and other extended attributes from both
  installed app bundles and restore readable/executable bundle permissions, so
  users do not have to repeat manual System Settings/open-from-Finder prompts
  for the two no-SIP app bundles.
- When the combined package carries a missing or newer `vEGPU Machine.app`
  build, the Distribution selects the Machine component. Its preinstall script
  asks the installed Machine app to run `--driver-deactivate` before replacement
  when an older Machine app exists. If graceful deactivation fails, it falls back
  to `systemextensionsctl uninstall - com.vegpu.machine.VFIOUserPCIDriver`.
  After replacement, the Machine component postinstall script runs
  `--driver-activate` as the logged-in console user.
- If the installed `vEGPU Machine.app` is the same or newer than the package
  payload, the Distribution does not select the Machine component, so the
  existing app and driver state are left alone.
- The combined package marks the Machine component with a restart recommendation
  so macOS Installer shows the final Restart Now / Later choice after the driver
  refresh path runs.
- The installed bundles include the corresponding source tarballs/source
  bundles for licensing obligations.

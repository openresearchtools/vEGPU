# PEGPU Release Repository Layout

This repo builds `PEGPU.app`, the Apache-side Swift/AppKit application. It does
not vendor QEMU, firmware, VFIO DriverKit code, or guest GPL source. Those live
in the separate `PEGPU Machine.app` build.
The installed `PEGPU.app` legal bundle has two surfaces. `LICENSES` is the
app-visible distribution license bundle for installed runtime payloads, helper
programs, framework dependencies, and app-managed runtime archives. Source
archives under `legal/generated/source/` have adjacent generated `.NOTICES`,
`.LICENSES`, and `.manifest.json` sidecars for the files inside those archives.

## Repositories

- `openresearchtools/PEGPU`: builds `PEGPU.app`.
- `openresearchtools/PEGPU-machine`: builds `PEGPU Machine.app`, QEMU/VFIO,
  firmware, guest tools, Machine notices, and Machine source bundles.

The public download can still be one `.pkg`. The package should install both
apps into `/Applications`, but the source trees and license payloads stay
separate.

## PEGPU App Build

Do not use raw `swift build` as a release build entrypoint. `Package.swift`
intentionally points at a generated CocoaSpice package path, and CI creates
that package from the pinned UTM source plus `third_party/utm/patches` before
SwiftPM runs. The supported build entrypoint is the bundle script below, and
the public release path is the GitHub Actions workflow.

```sh
CONFIGURATION=release scripts/build-app-bundle.sh
```

The bundle script writes generated dependencies and SwiftPM scratch data under
`$RUNNER_TEMP`/`$PEGPU_BUILD_ROOT`, not into the repository.

The app build generates current legal payloads under:

```text
$RUNNER_TEMP/pegpu-artifacts/legal/generated
$RUNNER_TEMP/pegpu-artifacts/app/PEGPU.app/Contents/Resources/PEGPURoot/legal/generated
```

The generated folder contains:

- `NOTICES`
- `LICENSES`
- `NOTICES.md` compatibility copy
- `manifest.json`
- copied scoped app distribution license inputs under `license-files/`
- `source/PEGPU-app-source.tar.gz`
- `source/PEGPU-app-source.NOTICES`
- `source/PEGPU-app-source.LICENSES`
- `source/PEGPU-app-source.manifest.json`
- `source/display-runtime-source.tar.gz`
- `source/display-runtime-source.NOTICES`
- `source/display-runtime-source.LICENSES`
- `source/display-runtime-source.manifest.json`

Legacy `THIRD_PARTY_*` files are not copied into the app bundle.

## Strict Release Source Check

For public release builds, require the copied display-runtime corresponding
source archive:

```sh
PEGPU_REQUIRE_FULL_SOURCE=1 CONFIGURATION=release scripts/build-app-bundle.sh
```

That expects the display-runtime source artifact path from CI, normally:

```text
$RUNNER_TEMP/pegpu-input/display-runtime-source/display-runtime-source.tar.gz
```

This is deliberately strict: the current app bundles SPICE/GLib/GStreamer/etc
frameworks copied from the UTM display runtime, so the public release must carry
the matching app-side display source/provenance bundle instead of relying on
stale legacy notices. The installed PEGPU.app display source archive may include
build/source inputs needed to reproduce the app-side display runtime. Its
adjacent source-archive sidecars carry the exhaustive license/notice records for
the archive contents.

## Source-Built Display Runtime

For a release build, generate the app-side display frameworks from the pinned
UTM dependency recipe:

```sh
PEGPU_UTM_REPO="https://github.com/<owner>/<utm-display-runtime-fork>.git" \
PEGPU_UTM_COMMIT="e4a4c34b671284263fc69f81b607de494d7e9b65" \
scripts/build-display-runtime-from-source.sh
```

This script uses UTM only as a dependency recipe source. It does not build
UTM.app and it does not build QEMU. It builds the SPICE client stack,
GLib/GStreamer/libsoup/libusb dependencies, and ANGLE frameworks needed by
`PEGPU.app`.

Outputs:

```text
$RUNNER_TEMP/pegpu-artifacts/display-frameworks/macos-arm64
$RUNNER_TEMP/pegpu-artifacts/display-runtime-source/display-runtime-source.tar.gz
```

## GitHub Actions

`.github/workflows/build.yml` supports three release modes:

- `artifact-only`: build source-backed display frameworks, build the Linux
  scaling helper package, build `PEGPU.app`, trigger/fetch `PEGPU Machine`
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
- `release_version` / `build_number`: written into `PEGPU.app`
  `CFBundleShortVersionString` and `CFBundleVersion`; when `machine_mode=trigger`
  the same values are passed to the Machine workflow so a newly built
  `PEGPU Machine.app` carries matching version metadata.
- `llama_runtime_tag`: selects the bundled llama.cpp runtime release from
  `openresearchtools/llama-cpp-arm64-builds`; `latest` resolves to the newest
  stable llama.cpp release and bundles macOS, Debian Trixie CUDA 13, and Debian
  Trixie Vulkan ARM64 archives.
- `publish_release=true`: manual override to publish a release from
  `artifact-only`; release assets still contain only the combined `.pkg`.

For cross-repo Machine triggering, set a repository secret named
`PEGPU_MACHINE_TOKEN` with permission to run and read workflow artifacts from
the Machine repository.

## Cache Policy

CI caches only generated outputs under GitHub runner cache/temp paths. It does
not write cached build products into the checkout.

- Display runtime: exact artifact cache keyed by UTM commit, display build
  scripts, normalization script, and PEGPU UTM patches. On a hit, the job skips
  Homebrew setup and the full SPICE/GLib/GStreamer/ANGLE rebuild.
- Display runtime work tree: secondary cache for downloaded/upstream build
  state, used only when the exact display artifact cache misses.
- Scaling package: exact package cache keyed by the scaling helper source and
  package script. On a hit, the Debian container build is skipped.
- PEGPU.app: exact app/legal payload cache keyed by Swift sources, resources,
  Go router sources, app build/legal scripts, display runtime inputs, scaling
  package inputs, docs, legal files, and UTM patches. On a hit, the app build is
  skipped and the restored app is still validated and uploaded.
- SwiftPM and patched UTM package worktree: incremental caches used only when
  `PEGPU.app` itself has to rebuild.

Machine/QEMU/DKMS artifacts are not guessed from this repo cache. The workflow
either downloads a specific Machine run or triggers the Machine workflow so the
Machine repository remains the source of truth for its own cache and rebuild
decisions.

## PEGPU Machine Notices

`PEGPU Machine.app` carries its own notices and source bundles inside that app,
for example:

```text
/Applications/PEGPU Machine.app/Contents/Resources/ThirdPartyNotices
/Applications/PEGPU Machine.app/Contents/Resources/guest-tools/source
```

`PEGPU.app` exposes Help menu items to open `PEGPU Machine.app` and reveal those
Machine notices. Do not duplicate Machine GPL source inside the Apache-side
PEGPU app unless the release package intentionally adds a top-level convenience
copy.

## One-Package Release Shape

A public `.pkg` should contain:

- `/Applications/PEGPU.app`
- `/Applications/PEGPU Machine.app`
- optional top-level release notes

Build it from an already built Machine app:

```sh
PEGPU_MACHINE_APP="/path/to/PEGPU Machine.app" \
VERSION=0.1.0 \
scripts/build-release-pkg.sh
```

The package license screen should mention that the install contains two apps
with separate notices and that PEGPU.app `LICENSES` is a scoped distribution
license bundle:

- PEGPU app notices/licenses: `PEGPU.app/Contents/Resources/PEGPURoot/legal/generated/NOTICES`
  and `PEGPU.app/Contents/Resources/PEGPURoot/legal/generated/LICENSES`
- PEGPU Machine notices/source: `PEGPU Machine.app/Contents/Resources`

The app Help menu points users to both.

Package names are channel-specific:

- `PEGPU-v0.1.0-artifact.pkg` for artifact-only workflow runs.
- `PEGPU-v0.1.0-pre-release.pkg` for prereleases.
- `PEGPU-v0.1.0.pkg` for stable releases.

The package welcome/readme/license resources also state:

- `https://pegpu.com`
- `https://github.com/openresearchtools/PEGPU`
- `https://github.com/openresearchtools/PEGPU-machine`
- SIP must be disabled before installation; the package preinstall scripts
  refuse installation when `csrutil status` is not disabled and print the
  Apple Silicon recovery Terminal steps.
- Postinstall scripts clear quarantine and other extended attributes from both
  installed app bundles and restore readable/executable bundle permissions, so
  users do not have to repeat manual System Settings/open-from-Finder prompts
  for the two no-SIP app bundles.
- When the combined package carries a missing or newer `PEGPU Machine.app`
  build, the Distribution selects the Machine component. Its preinstall script
  asks the installed Machine app to run `--driver-deactivate` before replacement
  when an older Machine app exists. If graceful deactivation fails, it falls back
  to `systemextensionsctl uninstall - com.pegpu.machine.VFIOUserPCIDriver`.
  After replacement, the Machine component postinstall script runs
  `--driver-activate` as the logged-in console user.
- If the installed `PEGPU Machine.app` is the same or newer than the package
  payload, the Distribution does not select the Machine component, so the
  existing app and driver state are left alone.
- The combined package marks the Machine component with a restart recommendation
  so macOS Installer shows the final Restart Now / Later choice after the driver
  refresh path runs.
- The installed bundles include the corresponding source tarballs/source
  bundles for licensing obligations.

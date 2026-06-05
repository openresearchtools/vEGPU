# ANGLE Runtime Source

vEGPU imports ANGLE runtime artifacts on the app side only. The source of truth is UTM's WebKit fork, not `utmapp/angle`.

- Source URL: https://github.com/utmapp/WebKit/tree/main/Source/ThirdParty/ANGLE
- Pinned commit: `ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10`
- Subtree: `Source/ThirdParty/ANGLE`
- Build scheme: `ANGLE`
- Output boundary: the CI `vEGPU-display-frameworks-macos-arm64` artifact, normally staged under `$RUNNER_TEMP/vegpu-artifacts/display-frameworks/macos-arm64`.
- Machine boundary: vEGPU Machine/QEMU consumes these at runtime through an app-provided framework directory; it must not vendor WebKit, ANGLE source, or these frameworks.

The upstream `ANGLE.plist` records:

- Open source project: ANGLE
- Open source version: `40dfb3a8bd6514b613ce693962c6d8dcd70ab25a`
- Import date: `2024-02-15`
- License: BSD-3-Clause (the upstream `ANGLE.plist` records this generically as BSD; the bundled `LICENSE` text is the 3-clause BSD form)
- License file: `LICENSE`

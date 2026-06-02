#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bad_paths="$(
  find . \
    -path './.git' -prune -o \
    \( \
      -path './.build' -o \
      -path './.swiftpm' -o \
      -path './build' -o \
      -path './recovery-backups' -o \
      -path './tools/bin' -o \
      -path './UTM-Derived' -o \
      -path './Resources/Guest/scaling-app/build' -o \
      -path './Resources/Guest/scaling-app/package' -o \
      -path './ai/web-ui-app/.runtime-downloads' -o \
      -path './ai/web-ui-app/runtimes' \
    \) -print
)"
if [ -n "$bad_paths" ]; then
  printf 'Forbidden generated/vendor folders found:\n%s\n' "$bad_paths" >&2
  exit 1
fi

bad_artifacts="$(
  find . -path './.git' -prune -o -type f \( \
    -path './Resources/Assets/vEGPU.icns' -o \
    -path './Resources/Assets/vEGPU-logo-transparent.png' -o \
    -path './Resources/Assets/vEGPU-tray.png' \
  \) -prune -o -type f \( \
    -name '.DS_Store' -o \
    -name '*.app' -o \
    -name '*.pkg' -o \
    -name '*.dmg' -o \
    -name '*.framework' -o \
    -name '*.dylib' -o \
    -name '*.a' -o \
    -name '*.o' -o \
    -name '*.deb' -o \
    -name '*.pyc' -o \
    -name '*.zip' -o \
    -name '*.tar.gz' -o \
    -name '*.tar.xz' -o \
    -name '*.tar.zst' -o \
    -name '*.tgz' -o \
    -name '*.icns' -o \
    -name '*.png' -o \
    -name '*.jpg' -o \
    -name '*.jpeg' \
  \) -print
)"
if [ -n "$bad_artifacts" ]; then
  printf 'Forbidden binary/generated artifacts found:\n%s\n' "$bad_artifacts" >&2
  exit 1
fi

binary_payloads="$(
  find . -path './.git' -prune -o \( \
      -path './Resources/Assets/vEGPU.icns' -o \
      -path './Resources/Assets/vEGPU-logo-transparent.png' -o \
      -path './Resources/Assets/vEGPU-tray.png' \
    \) -prune -o -type f -print0 |
    xargs -0 file |
    grep -E 'Mach-O|Debian binary package|current ar archive|Zip archive|xar archive|gzip compressed|XZ compressed|PNG image|JPEG image|Apple icon' || true
)"
if [ -n "$binary_payloads" ]; then
  printf 'Forbidden binary payloads detected by file(1):\n%s\n' "$binary_payloads" >&2
  exit 1
fi

test_payloads="$(
  find . \
    -path './.git' -prune -o \
    \( \
      -path './Sources/vEGPUCoreSelfTests' -o \
      -path './Resources/Guest/scaling-app/tests' -o \
      -path '*/__pycache__' -o \
      -name '*_test.go' -o \
      -name 'test_*.py' \
    \) -print
)"
if [ -n "$test_payloads" ]; then
  printf 'Clean repo must not contain test-only payloads:\n%s\n' "$test_payloads" >&2
  exit 1
fi

test -f legal/NOTICES.md
test -f legal/LICENSES/llama-swap-MIT.txt
test -f legal/LICENSES/llama.cpp-MIT.txt
test -f legal/LICENSES/UTM-Apache-2.0.txt
test -f legal/LICENSES/vegpu-scaling-MIT.txt
test -f releases/releases-manifest.json
test -f releases/pre-releases-manifest.json
test -f third_party/angle/LICENSE
test -f third_party/utm/README.md
test -f third_party/utm/patches/0001-openresearchtools-vegpu-cocoaspice-package.patch
test -s third_party/utm/patches/0001-openresearchtools-vegpu-cocoaspice-package.patch

allowed_scripts="$(
  cat <<'LIST'
scripts/apply-utm-patches.sh
scripts/build-app-bundle.sh
scripts/build-display-runtime-from-source.sh
scripts/build-legal-bundle.sh
scripts/build-release-pkg.sh
scripts/build-scaling-app-package.sh
scripts/fetch-machine-artifacts.sh
scripts/normalize-display-frameworks.sh
scripts/verify-clean-repo.sh
LIST
)"
unexpected_scripts="$(
  find scripts -maxdepth 1 -type f -name '*.sh' -print |
    sort |
    comm -23 - <(printf '%s\n' "$allowed_scripts" | sort)
)"
if [ -n "$unexpected_scripts" ]; then
  printf 'Unexpected local-only scripts found:\n%s\n' "$unexpected_scripts" >&2
  exit 1
fi

bad_release_files="$(find releases -type f ! -name '*.json' -print 2>/dev/null || true)"
if [ -n "$bad_release_files" ]; then
  printf 'Release manifest directory must contain JSON manifests only:\n%s\n' "$bad_release_files" >&2
  exit 1
fi

if rg -n 'UTM-Derived' Package.swift scripts .github Sources legal third_party -g '!scripts/verify-clean-repo.sh' >/tmp/vegpu-clean-rg.$$ 2>/dev/null; then
  cat /tmp/vegpu-clean-rg.$$ >&2
  rm -f /tmp/vegpu-clean-rg.$$
  printf 'Committed clean repo must not reference UTM-Derived source paths.\n' >&2
  exit 1
fi
rm -f /tmp/vegpu-clean-rg.$$

if rg -n '\$ROOT/build|path: build/|OUT="build/|\$PWD/build|go build -o web-ui-app|go build -o gost-local-proxy|\$ROOT/tools|build-angle-frameworks|prepare-clean-release-repo|build/generated/display-frameworks|build/vEGPU\.app|build/legal/generated' Package.swift .github scripts Sources Resources docs ai third_party -g '!scripts/verify-clean-repo.sh' >/tmp/vegpu-clean-rg.$$ 2>/dev/null; then
  cat /tmp/vegpu-clean-rg.$$ >&2
  rm -f /tmp/vegpu-clean-rg.$$
  printf 'Build scripts/workflows must not write generated outputs into the checkout or keep local fallback builders.\n' >&2
  exit 1
fi
rm -f /tmp/vegpu-clean-rg.$$

if rg -n '/Users/user|/var/folders|NSIRD_|TemporaryItems|modelPath: /Users|mmprojPath: /Users' ai docs legal Package.swift scripts Sources Resources .github -g '!scripts/verify-clean-repo.sh' >/tmp/vegpu-clean-rg.$$ 2>/dev/null; then
  cat /tmp/vegpu-clean-rg.$$ >&2
  rm -f /tmp/vegpu-clean-rg.$$
  printf 'Clean repo must not contain machine-local paths or discovered model config.\n' >&2
  exit 1
fi
rm -f /tmp/vegpu-clean-rg.$$

if rg -n 'Electron/Node|Electron app|Electron-era|Electron/Chromium' docs legal scripts .github Package.swift Sources Resources -g '!scripts/verify-clean-repo.sh' >/tmp/vegpu-clean-rg.$$ 2>/dev/null; then
  cat /tmp/vegpu-clean-rg.$$ >&2
  rm -f /tmp/vegpu-clean-rg.$$
  printf 'Clean repo docs/notices must not describe the old Electron architecture.\n' >&2
  exit 1
fi
rm -f /tmp/vegpu-clean-rg.$$

if rg -n 'vEGPUCoreSelfTests|go test|unittest discover' Package.swift .github scripts docs Resources -g '!scripts/verify-clean-repo.sh' >/tmp/vegpu-clean-rg.$$ 2>/dev/null; then
  cat /tmp/vegpu-clean-rg.$$ >&2
  rm -f /tmp/vegpu-clean-rg.$$
  printf 'Clean repo must not reference removed test runners.\n' >&2
  exit 1
fi
rm -f /tmp/vegpu-clean-rg.$$

empty_dirs="$(find . -path './.git' -prune -o -type d -empty -print)"
if [ -n "$empty_dirs" ]; then
  printf 'Clean repo must not contain empty placeholder directories:\n%s\n' "$empty_dirs" >&2
  exit 1
fi

echo "clean repo verification passed"

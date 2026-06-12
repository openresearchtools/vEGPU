#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pegpu-build"
BUILD_ROOT="${PEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
OUT="${PEGPU_PERFORMANCE_PACKAGE_OUT:-$BUILD_ROOT/guest-packages/performance-app}"
VERSION="${PEGPU_PERFORMANCE_VERSION:-0.1.0}"
ARCH="${PEGPU_PERFORMANCE_ARCH:-arm64}"
BUILD_DIR="${PEGPU_PERFORMANCE_BUILD_DIR:-$BUILD_ROOT/performance-app-deb}"

command -v dpkg-deb >/dev/null 2>&1 || {
  printf 'dpkg-deb is required to build the Linux performance helper package.\n' >&2
  exit 1
}

rm -rf "$OUT" "$BUILD_DIR"
mkdir -p "$OUT" "$BUILD_DIR"

package="$(
  BUILD_DIR="$BUILD_DIR" \
  VERSION="$VERSION" \
  ARCH="$ARCH" \
  "$ROOT/Resources/Guest/performance-app/build-deb.sh" |
  tail -n 1
)"

cp "$package" "$OUT/"
(
  cd "$OUT"
  sha512sum "$(basename "$package")" > SHA512SUMS
)

printf '%s\n' "$OUT/$(basename "$package")"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vegpu-build"
BUILD_ROOT="${VEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
UTM_REPO="${VGPU_UTM_REPO:-${VEGPU_UTM_REPO:-https://github.com/utmapp/UTM.git}}"
UTM_COMMIT="${VGPU_UTM_COMMIT:-${VEGPU_UTM_COMMIT:-e4a4c34b671284263fc69f81b607de494d7e9b65}}"
WORK="${VGPU_DISPLAY_BUILD_DIR:-${VEGPU_DISPLAY_BUILD_DIR:-$BUILD_ROOT/display-runtime-source-build}}"
UTM_DIR="$WORK/utm-base"
DRIVER="$WORK/vegpu-display-driver.sh"
SOURCE_OUT="${VGPU_DISPLAY_SOURCE_OUT:-${VEGPU_DISPLAY_SOURCE_OUT:-$BUILD_ROOT/legal/display-runtime-source.tar.gz}}"
FRAMEWORKS_OUT="${VGPU_DISPLAY_FRAMEWORKS_OUT:-${VEGPU_DISPLAY_FRAMEWORKS_OUT:-$BUILD_ROOT/display-frameworks/macos-arm64}}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required tool: %s\n' "$1" >&2
    exit 1
  }
}

install_requirements_hint() {
  cat >&2 <<'EOF'
Install/build requirements expected by the UTM display dependency recipe:

  brew install bison pkg-config gettext glib-utils libgpg-error nasm make meson cmake llvm spirv-llvm-translator libxcb libxrandr
  python3 -m pip install --user six pyparsing pyyaml setuptools distlib mako

This builds only vEGPU's app-side SPICE/GLib/GStreamer/ANGLE framework set.
It does not build UTM.app and it does not build QEMU.
EOF
}

archive_git_snapshot() {
  local repo="$1"
  local out_dir="$2"
  local label="$3"
  shift 3
  local paths=("$@")
  local head
  head="$(git -C "$repo" rev-parse HEAD)"
  mkdir -p "$out_dir"
  git -C "$repo" rev-parse HEAD > "$out_dir/HEAD"
  git -C "$repo" remote get-url origin > "$out_dir/REMOTE" 2>/dev/null || true
  if [ "${#paths[@]}" -gt 0 ]; then
    git -C "$repo" archive \
      --format=tar \
      --prefix="$label-$head/" \
      HEAD -- "${paths[@]}" | gzip -c > "$out_dir/$label-source.tar.gz"
  else
    git -C "$repo" archive \
      --format=tar \
      --prefix="$label-$head/" \
      HEAD | gzip -c > "$out_dir/$label-source.tar.gz"
  fi
}

require git
require tar
require xcrun
require otool
if ! command -v brew >/dev/null 2>&1; then
  install_requirements_hint
  exit 1
fi

mkdir -p "$WORK" "$(dirname "$SOURCE_OUT")"

rm -rf "$UTM_DIR"
git clone --filter=blob:none "$UTM_REPO" "$UTM_DIR"
git -C "$UTM_DIR" fetch --tags --force origin "$UTM_COMMIT"
git -C "$UTM_DIR" checkout --force "$UTM_COMMIT"
git -C "$UTM_DIR" reset --hard "$UTM_COMMIT" >/dev/null
git -C "$UTM_DIR" clean -fdx >/dev/null
git -C "$UTM_DIR" submodule update --init --recursive
if [ -d "$ROOT/third_party/utm/patches" ]; then
  for patch in "$ROOT"/third_party/utm/patches/*.patch; do
    [ -e "$patch" ] || continue
    git -C "$UTM_DIR" apply --whitespace=nowarn --check "$patch"
    git -C "$UTM_DIR" apply --whitespace=nowarn "$patch"
  done
fi

# Reuse UTM's build functions and source records without modifying the UTM fork.
# The generated driver stops before UTM's command-line parser and full QEMU build.
awk '/^# parse args/ { exit } { print }' "$UTM_DIR/scripts/build_dependencies.sh" > "$DRIVER"
cat >> "$DRIVER" <<'DRIVER'

set -euo pipefail

UTM_DIR="${UTM_DIR:?}"
WORK="${WORK:?}"
NCPU="${NCPU:-0}"
ARCH=arm64
PLATFORM=macos
SDKMINVER="${SDKMINVER:-11.0}"
SDK=macosx
CPU=aarch64
CHOST="$CPU-apple-darwin"
PLATFORM_FAMILY_NAME=macOS
BUILD_DIR="$WORK/build-macOS-arm64"
SYSROOT_DIR="$WORK/sysroot-macOS-arm64"
SOURCE_PREFLIGHT="$WORK/source-preflight"
PATCHES_DIR="$UTM_DIR/patches"
REBUILD=
REDOWNLOAD="${VEGPU_DISPLAY_REDOWNLOAD:-}"
QEMU_DIR=
DEBUG=
DEBUG_FLAGS=
case "${CONFIGURATION:-Release}" in
  [Rr]elease)
    BUILD_CONFIGURATION="Release"
    ;;
  [Dd]ebug)
    BUILD_CONFIGURATION="Debug"
    ;;
  *)
    BUILD_CONFIGURATION="${CONFIGURATION:-Release}"
    ;;
esac

source "$PATCHES_DIR/sources"

SDKNAME=$(basename "$(xcrun --sdk "$SDK" --show-sdk-platform-path)" .platform)
SDKVERSION=$(xcrun --sdk "$SDK" --show-sdk-version)
SDKROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
CFLAGS_TARGET="-target $ARCH-apple-macos$SDKMINVER"
if [ -z "$NCPU" ] || [ "$NCPU" -eq 0 ]; then
  NCPU="$(sysctl -n hw.ncpu)"
fi

mkdir -p "$SYSROOT_DIR" "$SYSROOT_DIR/Frameworks"

CC="$(xcrun --sdk "$SDK" --find gcc) $CFLAGS_TARGET"
CPP="$(xcrun --sdk "$SDK" --find gcc) -E"
CXX="$(xcrun --sdk "$SDK" --find g++)"
OBJCC="$(xcrun --sdk "$SDK" --find clang)"
LD="$(xcrun --sdk "$SDK" --find ld)"
AR="$(xcrun --sdk "$SDK" --find ar)"
NM="$(xcrun --sdk "$SDK" --find nm)"
RANLIB="$(xcrun --sdk "$SDK" --find ranlib)"
STRIP="$(xcrun --sdk "$SDK" --find strip)"
PREFIX="$(realpath "$SYSROOT_DIR")"
export ARCH SDK SDKMINVER CC CPP CXX OBJCC LD AR NM RANLIB STRIP PREFIX CHOST NCPU BUILD_CONFIGURATION

CFLAGS="${CFLAGS:-} -arch $ARCH -isysroot $SDKROOT -I$PREFIX/include -F$PREFIX/Frameworks"
CPPFLAGS="${CPPFLAGS:-} -arch $ARCH -isysroot $SDKROOT -I$PREFIX/include -F$PREFIX/Frameworks $CFLAGS_TARGET"
CXXFLAGS="${CXXFLAGS:-} -arch $ARCH -isysroot $SDKROOT -I$PREFIX/include -F$PREFIX/Frameworks $CFLAGS_TARGET"
OBJCFLAGS="${OBJCFLAGS:-} -arch $ARCH -isysroot $SDKROOT -I$PREFIX/include -F$PREFIX/Frameworks $CFLAGS_TARGET"
LDFLAGS="${LDFLAGS:-} -arch $ARCH -isysroot $SDKROOT -L$PREFIX/lib -F$PREFIX/Frameworks $CFLAGS_TARGET"
export CFLAGS CPPFLAGS CXXFLAGS OBJCFLAGS LDFLAGS

archive_git_snapshot() {
  local repo="$1"
  local out_dir="$2"
  local label="$3"
  shift 3
  local paths=("$@")
  local head
  head="$(git -C "$repo" rev-parse HEAD)"
  mkdir -p "$out_dir"
  git -C "$repo" rev-parse HEAD > "$out_dir/HEAD"
  git -C "$repo" remote get-url origin > "$out_dir/REMOTE" 2>/dev/null || true
  if [ "${#paths[@]}" -gt 0 ]; then
    git -C "$repo" archive \
      --format=tar \
      --prefix="$label-$head/" \
      HEAD -- "${paths[@]}" | gzip -c > "$out_dir/$label-source.tar.gz"
  else
    git -C "$repo" archive \
      --format=tar \
      --prefix="$label-$head/" \
      HEAD | gzip -c > "$out_dir/$label-source.tar.gz"
  fi
}

download_display_sources() {
  mkdir -p "$BUILD_DIR"
  download "$PKG_CONFIG_SRC"
  download "$FFI_SRC"
  download "$ICONV_SRC"
  download "$GETTEXT_SRC"
  download "$PNG_SRC"
  download "$JPEG_TURBO_SRC"
  download "$GLIB_SRC"
  download "$GPG_ERROR_SRC"
  download "$GCRYPT_SRC"
  download "$PIXMAN_SRC"
  download "$OPENSSL_SRC"
  download "$OPUS_SRC"
  download "$ZSTD_SRC"
  download "$GST_SRC"
  download "$GST_BASE_SRC"
  download "$GST_GOOD_SRC"
  download "$SPICE_PROTOCOL_SRC"
  download "$USB_SRC"
  download "$USBREDIR_SRC"
  download "$JSON_GLIB_SRC"
  download "$XML2_SRC"
  download "$SOUP_SRC"
  download "$PHODAV_SRC"
  download "$SPICE_CLIENT_SRC"
  ensure_git_checkout "$WEBKIT_REPO" "$WEBKIT_COMMIT" "$WEBKIT_SUBDIRS"
  ensure_git_checkout "$LIBUCONTEXT_REPO" "$LIBUCONTEXT_COMMIT" ""
}

ensure_git_checkout() {
  local repo="$1"
  local commit="$2"
  local subdirs="${3:-}"
  local name
  local dir
  name="$(basename "$repo")"
  dir="$BUILD_DIR/$name"
  if [ -d "$dir/.git" ] && git -C "$dir" cat-file -e "$commit^{commit}" >/dev/null 2>&1; then
    git -C "$dir" checkout --force "$commit"
    return
  fi
  rm -rf "$dir"
  clone "$repo" "$commit" "$subdirs"
}

ensure_display_git_sources() {
  mkdir -p "$BUILD_DIR"
  ensure_git_checkout "$LIBUCONTEXT_REPO" "$LIBUCONTEXT_COMMIT" ""
}

stage_display_source_preflight() {
  local webkit_repo="$BUILD_DIR/WebKit.git"
  if [ ! -d "$webkit_repo/.git" ]; then
    printf 'Display runtime source preflight failed: missing WebKit.git checkout containing ANGLE source: %s\n' "$webkit_repo" >&2
    exit 1
  fi

  rm -rf "$SOURCE_PREFLIGHT"
  local webkit_source_paths=()
  if [ -n "${WEBKIT_SUBDIRS:-}" ]; then
    # UTM's recipe checks out only the display runtime WebKit subtree we need.
    # Archive that snapshot, not the full WebKit git history.
    read -r -a webkit_source_paths <<< "$WEBKIT_SUBDIRS"
  fi
  archive_git_snapshot \
    "$webkit_repo" \
    "$SOURCE_PREFLIGHT/git-sources/WebKit.git" \
    "WebKit" \
    "${webkit_source_paths[@]}"

  if [ ! -f "$SOURCE_PREFLIGHT/git-sources/WebKit.git/WebKit-source.tar.gz" ]; then
    printf 'Display runtime source preflight failed: could not create WebKit/ANGLE source snapshot.\n' >&2
    exit 1
  fi
}

have_display_frameworks() {
  [ -d "$PREFIX/Frameworks/spice-client-glib-2.0.8.framework" ] &&
    [ -d "$PREFIX/Frameworks/EGL.framework" ] &&
    [ -d "$PREFIX/Frameworks/GLESv2.framework" ]
}

have_source_preflight() {
  [ -f "$SOURCE_PREFLIGHT/git-sources/WebKit.git/WebKit-source.tar.gz" ] &&
    [ -f "$SOURCE_PREFLIGHT/git-sources/WebKit.git/HEAD" ]
}

build_angle() {
  OLD_PATH="$PATH"
  export PATH="$(realpath "$BUILD_DIR/depot_tools.git"):$OLD_PATH"
  pwd="$(pwd)"
  cd "$BUILD_DIR/WebKit.git/Source/ThirdParty/ANGLE"
  env -i \
    PATH="$PATH" \
    HOME="${HOME:-/tmp}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    DEVELOPER_DIR="$(xcode-select -p)" \
    LANG="${LANG:-en_US.UTF-8}" \
    NSUnbufferedIO=YES \
    xcodebuild archive \
      -archivePath "ANGLE" \
      -scheme "ANGLE" \
      -sdk "$SDK" \
      -arch "$ARCH" \
      -configuration "$BUILD_CONFIGURATION" \
      -derivedDataPath "$BUILD_DIR/angle-derived-data" \
      -jobs "${VEGPU_XCODE_JOBS:-4}" \
      WEBCORE_LIBRARY_DIR="/usr/local/lib" \
      NORMAL_UMBRELLA_FRAMEWORKS_DIR="" \
      CODE_SIGNING_ALLOWED=NO \
      COMPILER_INDEX_STORE_ENABLE=NO \
      IPHONEOS_DEPLOYMENT_TARGET="14.0" \
      MACOSX_DEPLOYMENT_TARGET="11.0" \
      XROS_DEPLOYMENT_TARGET="1.0"
  rsync -a "ANGLE.xcarchive/Products/usr/local/lib/" "$PREFIX/lib"
  rsync -a "include/" "$PREFIX/include"
  cd "$pwd"
  export PATH="$OLD_PATH"
}

build_display_frameworks() {
  echo "${GREEN}Starting vEGPU app display runtime build for macOS arm64 [${NCPU} jobs]${NC}"
  if have_display_frameworks && have_source_preflight && [ "${VEGPU_DISPLAY_FORCE_REBUILD:-0}" != "1" ]; then
    ensure_display_git_sources
    echo "${GREEN}Reusing existing display runtime frameworks and source preflight from $WORK${NC}"
    return
  fi
  check_env
  download_display_sources
  stage_display_source_preflight
  if have_display_frameworks && [ "${VEGPU_DISPLAY_FORCE_REBUILD:-0}" != "1" ]; then
    echo "${GREEN}Reusing existing display runtime frameworks from $PREFIX after refreshing source preflight${NC}"
    return
  fi
  rm -rf "$PREFIX/"*
  rm -f "$BUILD_DIR/meson"*.cross "$BUILD_DIR/cross.cmake"
  mkdir -p "$PREFIX/Frameworks"
  build_pkg_config
  build "$FFI_SRC"
  build "$ICONV_SRC"
  gl_cv_onwards_func_strchrnul=future build "$GETTEXT_SRC" --disable-java
  build "$PNG_SRC"
  build "$JPEG_TURBO_SRC"
  meson_build "$GLIB_SRC" -Dtests=false -Ddtrace=disabled
  build "$GPG_ERROR_SRC"
  build "$GCRYPT_SRC"
  build "$PIXMAN_SRC"
  build_openssl "$OPENSSL_SRC"
  build "$OPUS_SRC"
  ZSTD_BASENAME="$(basename "$ZSTD_SRC")"
  meson_build "$BUILD_DIR/${ZSTD_BASENAME%.tar.*}/build/meson"
  meson_build "$GST_SRC" -Dtests=disabled -Ddefault_library=both -Dregistry=false
  meson_build "$GST_BASE_SRC" -Dtests=disabled -Ddefault_library=both -Dgl=disabled
  meson_build "$GST_GOOD_SRC" -Dtests=disabled -Ddefault_library=both
  meson_build "$SPICE_PROTOCOL_SRC"
  build "$USB_SRC"
  meson_build "$USBREDIR_SRC"
  meson_build "$LIBUCONTEXT_REPO" -Ddefault_library=static -Dfreestanding=true
  meson_build "$JSON_GLIB_SRC" -Dintrospection=disabled
  build "$XML2_SRC" --enable-shared=no --without-python
  meson_build "$SOUP_SRC" -Dsysprof=disabled -Dtls_check=false -Dintrospection=disabled
  meson_build "$PHODAV_SRC"
  meson_build "$SPICE_CLIENT_SRC" -Dcoroutine=libucontext
  build_angle
  fixup_all
  remove_shared_gst_plugins || true
}

build_display_frameworks
DRIVER

chmod +x "$DRIVER"
UTM_DIR="$UTM_DIR" WORK="$WORK" CONFIGURATION="${CONFIGURATION:-Release}" "$DRIVER"

SYSROOT="$WORK/sysroot-macOS-arm64"
if [ ! -d "$SYSROOT/Frameworks" ]; then
  printf 'Display dependency build did not produce Frameworks: %s\n' "$SYSROOT/Frameworks" >&2
  exit 1
fi

rm -rf "$FRAMEWORKS_OUT"
mkdir -p "$FRAMEWORKS_OUT"
rsync -a --delete --include='*.framework/***' --include='*.framework' --exclude='*' \
  "$SYSROOT/Frameworks/" "$FRAMEWORKS_OUT/"
"$ROOT/scripts/normalize-display-frameworks.sh" "$FRAMEWORKS_OUT"

if [ ! -d "$FRAMEWORKS_OUT/spice-client-glib-2.0.8.framework" ]; then
  printf 'Source build did not produce spice-client-glib framework in %s\n' "$FRAMEWORKS_OUT" >&2
  exit 1
fi
if [ ! -d "$FRAMEWORKS_OUT/EGL.framework" ] || [ ! -d "$FRAMEWORKS_OUT/GLESv2.framework" ]; then
  printf 'Source build did not produce ANGLE EGL/GLESv2 frameworks in %s\n' "$FRAMEWORKS_OUT" >&2
  exit 1
fi

SOURCE_STAGE="$WORK/display-runtime-source"
rm -rf "$SOURCE_STAGE"
mkdir -p "$SOURCE_STAGE"

rsync -a "$UTM_DIR/scripts/" "$SOURCE_STAGE/utm-scripts/"
rsync -a "$UTM_DIR/patches/" "$SOURCE_STAGE/utm-patches/"
rsync -a "$ROOT/third_party/utm/patches/" "$SOURCE_STAGE/vegpu-utm-patches/"
cp "$UTM_DIR/LICENSE" "$SOURCE_STAGE/UTM-LICENSE.txt"
git -C "$UTM_DIR" rev-parse HEAD > "$SOURCE_STAGE/UTM_COMMIT"
git -C "$UTM_DIR" remote get-url origin > "$SOURCE_STAGE/UTM_REMOTE"

find "$UTM_DIR" -maxdepth 1 -type f -name 'README*.md' -exec cp {} "$SOURCE_STAGE/" \;

BUILD_DIR="$WORK/build-macOS-arm64"
SOURCE_PREFLIGHT="$WORK/source-preflight"
mkdir -p "$SOURCE_STAGE/upstream-sources" "$SOURCE_STAGE/git-sources"
mkdir -p "$SOURCE_STAGE/git-sources/utm-base"
git -C "$UTM_DIR" archive \
  --format=tar \
  --prefix="utm-base-$UTM_COMMIT/" \
  "$UTM_COMMIT" | gzip -c > "$SOURCE_STAGE/git-sources/utm-base/utm-base-$UTM_COMMIT.tar.gz"
git -C "$UTM_DIR" rev-parse HEAD > "$SOURCE_STAGE/git-sources/utm-base/HEAD"
git -C "$UTM_DIR" remote get-url origin > "$SOURCE_STAGE/git-sources/utm-base/REMOTE"

if [ -d "$SOURCE_PREFLIGHT/git-sources/WebKit.git" ]; then
  mkdir -p "$SOURCE_STAGE/git-sources"
  rsync -a "$SOURCE_PREFLIGHT/git-sources/WebKit.git" "$SOURCE_STAGE/git-sources/"
fi

if [ -d "$BUILD_DIR" ]; then
  find "$BUILD_DIR" -maxdepth 1 -type f \( -name '*.tar.*' -o -name '*.tgz' -o -name '*.zip' \) -print0 |
    while IFS= read -r -d '' archive; do
      cp "$archive" "$SOURCE_STAGE/upstream-sources/"
    done
  find "$BUILD_DIR" -maxdepth 1 -type d -name '*.git' -print0 |
    while IFS= read -r -d '' repo; do
      name="$(basename "$repo")"
      label="${name%.git}"
      if [ "$name" = "WebKit.git" ] && [ -f "$SOURCE_STAGE/git-sources/WebKit.git/WebKit-source.tar.gz" ]; then
        continue
      fi
      if ! git -C "$repo" rev-parse --verify HEAD^{commit} >/dev/null 2>&1; then
        printf 'Skipping incomplete Git checkout in partial display state: %s\n' "$repo" >&2
        continue
      fi
      archive_git_snapshot "$repo" "$SOURCE_STAGE/git-sources/$name" "$label"
    done
fi

if [ ! -f "$SOURCE_STAGE/git-sources/WebKit.git/WebKit-source.tar.gz" ]; then
  printf 'Display runtime source bundle is missing the WebKit/ANGLE source snapshot.\n' >&2
  exit 1
fi
if [ ! -f "$SOURCE_STAGE/git-sources/WebKit.git/HEAD" ]; then
  printf 'Display runtime source bundle is missing the WebKit.git revision record.\n' >&2
  exit 1
fi
if [ ! -f "$SOURCE_STAGE/git-sources/libucontext.git/libucontext-source.tar.gz" ]; then
  printf 'Display runtime source bundle is missing the libucontext source snapshot.\n' >&2
  exit 1
fi
if [ ! -f "$SOURCE_STAGE/utm-patches/sources" ]; then
  printf 'Display runtime source bundle is missing UTM dependency source records.\n' >&2
  exit 1
fi
if [ ! -f "$SOURCE_STAGE/vegpu-utm-patches/0001-openresearchtools-vegpu-cocoaspice-package.patch" ]; then
  printf 'Display runtime source bundle is missing the vEGPU UTM patch stack.\n' >&2
  exit 1
fi

cat > "$SOURCE_STAGE/README" <<EOF
vEGPU app-side display runtime source bundle
===========================================

This archive accompanies the app-side display frameworks copied into:

  the vEGPU-display-frameworks-macos26-arm64 workflow artifact

It records the pinned UTM dependency recipe, UTM dependency patches/sources
file, downloaded upstream source archives, and git source bundles used to
produce the SPICE, GLib, GStreamer, libsoup, USB, ANGLE, and related app-side
frameworks. ANGLE is carried through UTM's pinned WebKit fork; its corresponding
source snapshot is included as:

  git-sources/WebKit.git/WebKit-source.tar.gz
  git-sources/WebKit.git/HEAD
  git-sources/WebKit.git/REMOTE

The pinned UTM base source snapshot that the vEGPU patch stack applies to is
included at:

  git-sources/utm-base/utm-base-$UTM_COMMIT.tar.gz

Source builder:

  UTM repo: $UTM_REPO
  UTM commit: $UTM_COMMIT
  vEGPU script: scripts/build-display-runtime-from-source.sh

Scope:

  This build does not build UTM.app.
  This build does not build QEMU.
  QEMU/VFIO/DriverKit source and notices are produced by vEGPU Machine.
EOF

(cd "$SOURCE_STAGE" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
echo "Display runtime source bundle contents:"
du -sh "$SOURCE_STAGE/upstream-sources" "$SOURCE_STAGE/git-sources" "$SOURCE_STAGE/utm-patches" "$SOURCE_STAGE/vegpu-utm-patches" 2>/dev/null || true
tar -C "$WORK" -czf "$SOURCE_OUT" "$(basename "$SOURCE_STAGE")"
du -sh "$SOURCE_OUT"

echo "$FRAMEWORKS_OUT"
echo "$SOURCE_OUT"

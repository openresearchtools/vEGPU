#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vegpu-build"
BUILD_ROOT="${VEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
OUT="${1:-$BUILD_ROOT/machine-artifacts}"
REPO="${VEGPU_MACHINE_REPOSITORY:-openresearchtools/vEGPU-machine}"
WORKFLOW="${VEGPU_MACHINE_WORKFLOW:-build-nosip.yml}"
REF="${VEGPU_MACHINE_REF:-main}"
RUN_ID="${VEGPU_MACHINE_RUN_ID:-}"
TRIGGER="${VEGPU_TRIGGER_MACHINE_BUILD:-0}"
VERSION="${VEGPU_RELEASE_VERSION:-}"
BUILD_NUMBER="${VEGPU_BUILD_NUMBER:-}"
LOCAL_ZIP="${VEGPU_MACHINE_ZIP:-}"
LOCAL_SOURCE="${VEGPU_MACHINE_SOURCE_TGZ:-}"
LOCAL_ARTIFACT_DIR="${VEGPU_MACHINE_ARTIFACT_DIR:-}"
REQUIRE_SOURCE="${VEGPU_REQUIRE_MACHINE_SOURCE:-1}"

rm -rf "$OUT"
mkdir -p "$OUT"

copy_local() {
  test -f "$LOCAL_ZIP"
  cp "$LOCAL_ZIP" "$OUT/"
  if [ -n "$LOCAL_SOURCE" ]; then
    test -f "$LOCAL_SOURCE"
    cp "$LOCAL_SOURCE" "$OUT/"
  elif [ "$REQUIRE_SOURCE" = "1" ]; then
    printf 'VEGPU_MACHINE_SOURCE_TGZ is required with local Machine zip when VEGPU_REQUIRE_MACHINE_SOURCE=1\n' >&2
    exit 1
  fi
}

copy_artifact_dir() {
  test -d "$LOCAL_ARTIFACT_DIR"
  mkdir -p "$OUT/downloaded"
  cp -R "$LOCAL_ARTIFACT_DIR"/. "$OUT/downloaded/"
}

download_run() {
  local run_id="$1"
  command -v gh >/dev/null 2>&1 || {
    printf 'GitHub CLI is required to download Machine artifacts from %s\n' "$REPO" >&2
    exit 1
  }
  gh run download "$run_id" \
    --repo "$REPO" \
    --pattern '*build-output*' \
    --dir "$OUT/downloaded"
}

trigger_and_wait() {
  command -v gh >/dev/null 2>&1 || {
    printf 'GitHub CLI is required to trigger Machine workflow %s in %s\n' "$WORKFLOW" "$REPO" >&2
    exit 1
  }
  if [ -z "$VERSION" ]; then
    printf 'VEGPU_RELEASE_VERSION is required when VEGPU_TRIGGER_MACHINE_BUILD=1\n' >&2
    exit 1
  fi

  start_epoch="$(date -u '+%s')"
  args=(
    workflow run "$WORKFLOW"
    --repo "$REPO"
    --ref "$REF"
    -f "release_version=$VERSION"
    -f "publish_release=false"
    -f "prerelease=true"
  )
  if [ -n "$BUILD_NUMBER" ]; then
    args+=(-f "build_number=$BUILD_NUMBER")
  fi
  gh "${args[@]}"

  printf 'Waiting for Machine workflow run in %s on %s...\n' "$REPO" "$REF" >&2
  found_run=""
  for _ in $(seq 1 120); do
    found_run="$(
      gh run list \
        --repo "$REPO" \
        --workflow "$WORKFLOW" \
        --branch "$REF" \
        --event workflow_dispatch \
        --limit 20 \
        --json databaseId,createdAt,status \
        --jq ".[] | select((.createdAt | fromdateiso8601) >= $start_epoch) | .databaseId" |
        head -n 1
    )"
    if [ -n "$found_run" ]; then
      break
    fi
    sleep 5
  done
  if [ -z "$found_run" ]; then
    printf 'Timed out finding triggered Machine run in %s\n' "$REPO" >&2
    exit 1
  fi
  gh run watch "$found_run" --repo "$REPO" --exit-status
  download_run "$found_run"
}

if [ -n "$LOCAL_ARTIFACT_DIR" ]; then
  copy_artifact_dir
elif [ -n "$LOCAL_ZIP" ]; then
  copy_local
elif [ -n "$RUN_ID" ]; then
  download_run "$RUN_ID"
elif [ "$TRIGGER" = "1" ]; then
  trigger_and_wait
else
  printf 'No Machine artifact source supplied.\n' >&2
  printf 'Set one of: VEGPU_MACHINE_ZIP, VEGPU_MACHINE_RUN_ID, or VEGPU_TRIGGER_MACHINE_BUILD=1.\n' >&2
  exit 1
fi

machine_zip="$(find "$OUT" -type f -name 'vEGPU-Machine-*.zip' | sort | head -n 1)"
machine_source="$(find "$OUT" -type f -name 'vEGPU-Machine-*-source.tar.gz' | sort | head -n 1 || true)"
if [ -z "$machine_zip" ]; then
  printf 'Downloaded Machine artifacts did not contain vEGPU-Machine-*.zip\n' >&2
  find "$OUT" -type f >&2
  exit 1
fi
if [ -z "$machine_source" ] && [ "$REQUIRE_SOURCE" = "1" ]; then
  printf 'Machine artifacts did not contain vEGPU-Machine-*-source.tar.gz\n' >&2
  find "$OUT" -type f >&2
  exit 1
fi

if [ -n "$machine_source" ]; then
  machine_source_top="$OUT/$(basename "$machine_source")"
  if [ "$machine_source" != "$machine_source_top" ]; then
    cp "$machine_source" "$machine_source_top"
    machine_source="$machine_source_top"
  fi
fi

rm -rf "$OUT/extracted"
mkdir -p "$OUT/extracted"
ditto -x -k "$machine_zip" "$OUT/extracted"
machine_app="$OUT/extracted/vEGPU Machine.app"
if [ ! -d "$machine_app" ]; then
  machine_app="$(find "$OUT/extracted" -maxdepth 3 -type d -name 'vEGPU Machine.app' | head -n 1)"
fi
if [ -z "$machine_app" ] || [ ! -d "$machine_app" ]; then
  printf 'Machine zip did not contain vEGPU Machine.app\n' >&2
  exit 1
fi

rm -rf "$OUT/vEGPU Machine.app"
ditto "$machine_app" "$OUT/vEGPU Machine.app"

{
  echo "machine_app=$OUT/vEGPU Machine.app"
  echo "machine_zip=$machine_zip"
  if [ -n "$machine_source" ]; then
    echo "machine_source=$machine_source"
  fi
} > "$OUT/outputs.env"

cat "$OUT/outputs.env"

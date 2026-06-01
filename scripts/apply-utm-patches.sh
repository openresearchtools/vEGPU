#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vegpu-build"
BUILD_ROOT="${VEGPU_BUILD_ROOT:-$DEFAULT_BUILD_ROOT}"
UTM_REPO="${VEGPU_UTM_REPO:-https://github.com/utmapp/UTM.git}"
UTM_COMMIT="${VEGPU_UTM_COMMIT:-e4a4c34b671284263fc69f81b607de494d7e9b65}"
WORKTREE="${VEGPU_UTM_PATCHED_WORKTREE:-$BUILD_ROOT/utm-patched}"
PATCH_DIR="${VEGPU_UTM_PATCH_DIR:-$ROOT/third_party/utm/patches}"

if [ ! -d "$PATCH_DIR" ]; then
  printf 'Missing UTM patch directory: %s\n' "$PATCH_DIR" >&2
  exit 1
fi

if [ ! -d "$WORKTREE/.git" ]; then
  rm -rf "$WORKTREE"
  mkdir -p "$(dirname "$WORKTREE")"
  git clone --filter=blob:none "$UTM_REPO" "$WORKTREE"
fi

git -C "$WORKTREE" fetch --tags --force origin "$UTM_COMMIT"
git -C "$WORKTREE" checkout --force "$UTM_COMMIT"
git -C "$WORKTREE" reset --hard "$UTM_COMMIT" >/dev/null
git -C "$WORKTREE" clean -fdx >/dev/null

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
if [ "${#patches[@]}" -eq 0 ]; then
  printf 'No UTM patch files found in %s\n' "$PATCH_DIR" >&2
  exit 1
fi

for patch in "${patches[@]}"; do
  git -C "$WORKTREE" apply --whitespace=nowarn --check "$patch"
  git -C "$WORKTREE" apply --whitespace=nowarn "$patch"
done

if [ ! -d "$WORKTREE/OpenResearchTools/CocoaSpice" ]; then
  printf 'UTM patch did not materialize OpenResearchTools/CocoaSpice in %s\n' "$WORKTREE" >&2
  exit 1
fi

printf '%s\n' "$WORKTREE"

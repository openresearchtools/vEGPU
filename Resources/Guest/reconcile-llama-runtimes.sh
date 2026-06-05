#!/usr/bin/env bash
set -euo pipefail

SEED_DIR=/var/lib/vegpu/llama-runtime-seed
MANIFEST=$SEED_DIR/llama-runtime-manifest.json
RUNTIME_ROOT=/home/vegpu/custom-llama-runtimes
FAMILY=llama

log() {
  printf '[vegpu-llama-runtime] %s\n' "$*" >&2
}

json_get() {
  jq -r "$1 // empty" "$2"
}

runtime_wrapper() {
  local root="$1"
  local rel="$2"
  local executable="$root/$rel"
  local bin_dir
  bin_dir="$(dirname "$executable")"
  cat <<EOF
#!/bin/sh
export LD_LIBRARY_PATH=$bin_dir:$root:$root/lib:\${LD_LIBRARY_PATH:-}
exec "$executable" "\$@"
EOF
}

managed_id_for_backend() {
  case "$1" in
    cuda13) printf '%s\n' managed-llama-cuda13-linux ;;
    vulkan) printf '%s\n' managed-llama-vulkan-linux ;;
    *) return 1 ;;
  esac
}

archive_for_backend() {
  local backend="$1"
  local rel seed_real archive
  rel="$(jq -r --arg backend "$backend" '.assets[$backend].path // empty' "$MANIFEST")"
  [ -n "$rel" ] || { log "manifest has no $backend runtime archive"; return 1; }
  seed_real="$(realpath -m "$SEED_DIR")"
  archive="$(realpath -m "$SEED_DIR/$rel")"
  case "$archive" in
    "$seed_real"/*) ;;
    *) log "refusing archive outside seed directory: $rel"; return 1 ;;
  esac
  [ -f "$archive" ] || { log "runtime archive missing: $archive"; return 1; }
  printf '%s\n' "$archive"
}

validate_archive() {
  local archive="$1"
  if tar -tzf "$archive" | grep -E '(^/|(^|/)[.][.](/|$))' >/dev/null; then
    log "refusing unsafe runtime archive paths: $archive"
    return 1
  fi
}

archive_sha_matches() {
  local archive="$1"
  local expected="$2"
  local actual
  [ -n "$expected" ] || return 0
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [ "$actual" = "$expected" ]
}

current_standard_backend() {
  local current target marker id family backend
  current="$RUNTIME_ROOT/current"
  target="$(readlink -f "$current" 2>/dev/null || true)"
  [ -n "$target" ] || { printf '%s\n' cuda13; return 0; }
  marker="$target/.vegpu-runtime.json"
  if [ -f "$marker" ]; then
    family="$(jq -r '.family // empty' "$marker" 2>/dev/null || true)"
    backend="$(jq -r '.backend // .linuxBackend // empty' "$marker" 2>/dev/null || true)"
    if [ "$family" = "$FAMILY" ] && { [ "$backend" = cuda13 ] || [ "$backend" = vulkan ]; }; then
      printf '%s\n' "$backend"
      return 0
    fi
    printf '\n'
    return 0
  fi
  id="$(basename "$target")"
  case "$id" in
    managed-llama-cuda13-linux|llama-*-cuda13-linux) printf '%s\n' cuda13 ;;
    managed-llama-vulkan-linux|llama-*-vulkan-linux) printf '%s\n' vulkan ;;
    *) printf '\n' ;;
  esac
}

marker_matches() {
  local marker="$1"
  local id="$2"
  local backend="$3"
  local tag="$4"
  local archive_name="$5"
  local sha="$6"
  [ -f "$marker" ] || return 1
  jq -e \
    --arg id "$id" \
    --arg family "$FAMILY" \
    --arg backend "$backend" \
    --arg tag "$tag" \
    --arg archive "$archive_name" \
    --arg sha "$sha" \
    '.id == $id and .family == $family and (.backend // .linuxBackend) == $backend and .releaseTag == $tag and .archiveName == $archive and .sha256 == $sha' \
    "$marker" >/dev/null 2>&1
}

write_marker() {
  local root="$1"
  local id="$2"
  local backend="$3"
  local tag="$4"
  local archive_name="$5"
  local sha="$6"
  local server_rel="$7"
  local rpc_rel="$8"
  local active="$9"
  jq -n \
    --arg id "$id" \
    --arg family "$FAMILY" \
    --arg releaseTag "$tag" \
    --arg backend "$backend" \
    --arg archiveName "$archive_name" \
    --arg sha256 "$sha" \
    --arg serverRel "$server_rel" \
    --arg rpcRel "$rpc_rel" \
    --arg installedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson active "$active" \
    '{
      id:$id,
      family:$family,
      releaseTag:$releaseTag,
      backend:$backend,
      archiveName:$archiveName,
      sha256:$sha256,
      serverRel:$serverRel,
      rpcRel:(if $rpcRel == "" then null else $rpcRel end),
      installedAt:$installedAt,
      active:$active
    }' >"$root/.vegpu-runtime.json"
  chown vegpu:vegpu "$root/.vegpu-runtime.json"
  chmod 0644 "$root/.vegpu-runtime.json"
}

server_rel_for_root() {
  local root="$1"
  local server
  server="$(find "$root" -type f -name llama-server -perm -111 -print -quit)"
  [ -n "$server" ] || return 1
  printf '%s\n' "${server#"$root"/}"
}

rpc_rel_for_root() {
  local root="$1"
  local rpc
  rpc="$(find "$root" -type f -name rpc-server -perm -111 -print -quit || true)"
  [ -n "$rpc" ] || return 0
  printf '%s\n' "${rpc#"$root"/}"
}

install_backend() {
  local backend="$1"
  local tag="$2"
  local id root tmp archive archive_name sha marker server rpc server_rel rpc_rel
  id="$(managed_id_for_backend "$backend")"
  root="$RUNTIME_ROOT/$id"
  tmp="$root.tmp"
  archive="$(archive_for_backend "$backend")"
  archive_name="$(jq -r --arg backend "$backend" '.assets[$backend].name // (.assets[$backend].path | split("/")[-1]) // empty' "$MANIFEST")"
  sha="$(jq -r --arg backend "$backend" '.assets[$backend].sha256 // empty' "$MANIFEST")"
  [ -n "$archive_name" ] || archive_name="$(basename "$archive")"
  archive_sha_matches "$archive" "$sha" || { log "$backend archive checksum mismatch"; return 1; }
  validate_archive "$archive"

  install -d -o vegpu -g vegpu -m 0755 "$RUNTIME_ROOT"
  marker="$root/.vegpu-runtime.json"
  if [ -d "$root" ] && marker_matches "$marker" "$id" "$backend" "$tag" "$archive_name" "$sha" &&
     find "$root" -type f -name llama-server -perm -111 -print -quit | grep -q .; then
    log "$backend runtime already current"
    return 0
  fi

  log "installing $backend runtime $tag"
  rm -rf "$tmp"
  install -d -o vegpu -g vegpu -m 0755 "$tmp"
  tar -xzf "$archive" -C "$tmp"
  server="$(find "$tmp" -type f -name llama-server -print -quit)"
  [ -n "$server" ] || { log "runtime archive has no llama-server: $archive"; rm -rf "$tmp"; return 1; }
  rpc="$(find "$tmp" -type f -name rpc-server -print -quit || true)"
  chmod 0755 "$server"
  [ -n "$rpc" ] && chmod 0755 "$rpc"
  chmod -R u+rwX,go+rX "$tmp"
  chown -R vegpu:vegpu "$tmp"
  rm -rf "$root"
  mv "$tmp" "$root"
  server_rel="$(server_rel_for_root "$root")"
  rpc_rel="$(rpc_rel_for_root "$root")"
  write_marker "$root" "$id" "$backend" "$tag" "$archive_name" "$sha" "$server_rel" "$rpc_rel" false
}

activate_backend() {
  local backend="$1"
  local id root server_rel rpc_rel marker
  id="$(managed_id_for_backend "$backend")"
  root="$RUNTIME_ROOT/$id"
  marker="$root/.vegpu-runtime.json"
  [ -d "$root" ] || { log "cannot activate missing runtime: $id"; return 1; }
  server_rel="$(server_rel_for_root "$root")"
  rpc_rel="$(rpc_rel_for_root "$root")"
  ln -sfn "$root" "$RUNTIME_ROOT/current"
  runtime_wrapper "$RUNTIME_ROOT/current" "$server_rel" >/usr/local/bin/llama-server
  chmod 0755 /usr/local/bin/llama-server
  if [ -n "$rpc_rel" ]; then
    runtime_wrapper "$RUNTIME_ROOT/current" "$rpc_rel" >/usr/local/bin/rpc-server
    chmod 0755 /usr/local/bin/rpc-server
  else
    rm -f /usr/local/bin/rpc-server
  fi
  for marker in "$RUNTIME_ROOT"/managed-llama-*-linux/.vegpu-runtime.json; do
    [ -f "$marker" ] || continue
    tmp_marker="$marker.tmp"
    jq --argjson active false '.active = $active' "$marker" >"$tmp_marker"
    mv "$tmp_marker" "$marker"
    chown vegpu:vegpu "$marker"
  done
  tmp_marker="$root/.vegpu-runtime.json.tmp"
  jq --argjson active true '.active = $active' "$root/.vegpu-runtime.json" >"$tmp_marker"
  mv "$tmp_marker" "$root/.vegpu-runtime.json"
  chown vegpu:vegpu "$root/.vegpu-runtime.json"
  log "active runtime backend: $backend"
}

main() {
  local tag active_backend changed
  [ -f "$MANIFEST" ] || { log "no bundled llama runtime seed found"; return 0; }
  tag="$(json_get '.tag' "$MANIFEST")"
  [ -n "$tag" ] || { log "runtime manifest has no tag"; return 1; }
  active_backend="$(current_standard_backend)"
  install_backend cuda13 "$tag"
  install_backend vulkan "$tag"
  if [ -n "$active_backend" ]; then
    activate_backend "$active_backend"
  fi
  changed=false
  jq -n \
    --arg tag "$tag" \
    --arg activeBackend "$active_backend" \
    --argjson changed "$changed" \
    '{ok:true, tag:$tag, activeBackend:$activeBackend, changed:$changed}'
}

main "$@"

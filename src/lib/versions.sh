#!/usr/bin/env bash
# current-versions.json 读写（flock 保护）

# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"

VERSIONS_LOCK_FD=201

_ensure_versions_file() {
  mkdir -p "${DEPLOY_ROOT}/data"
  if [[ ! -f "$VERSIONS_FILE" ]]; then
    echo "{}" >"$VERSIONS_FILE"
  fi
}

_with_versions_lock() {
  _ensure_versions_file
  (
    eval "exec ${VERSIONS_LOCK_FD}>\"${VERSIONS_FILE}\""
    flock "${VERSIONS_LOCK_FD}"
    "$@"
  )
}

versions_get() {
  local service="$1"
  _ensure_versions_file
  jq -r --arg s "$service" '.[$s].version_tag // ""' "$VERSIONS_FILE"
}

versions_set() {
  local service="$1" tag="$2"
  _with_versions_lock _versions_set_inner "$service" "$tag"
}

_versions_set_inner() {
  local service="$1" tag="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg s "$service" --arg t "$tag" \
    '.[$s] = {version_tag: $t}' \
    "$VERSIONS_FILE" >"$tmp"
  mv "$tmp" "$VERSIONS_FILE"
}

versions_ensure() {
  _with_versions_lock _versions_ensure_inner
}

_versions_ensure_inner() {
  local tmp merged
  tmp="$(mktemp)"
  merged="$(mktemp)"

  jq -n '{}' >"$merged"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local existing
    existing="$(jq -r --arg s "$name" '.[$s].version_tag // ""' "$VERSIONS_FILE" 2>/dev/null || echo "")"
    jq --arg s "$name" --arg t "$existing" \
      '.[$s] = {version_tag: $t}' \
      "$merged" >"$tmp"
    mv "$tmp" "$merged"
  done < <(service_names)

  mv "$merged" "$VERSIONS_FILE"
}

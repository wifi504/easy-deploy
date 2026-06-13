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
  mkdir -p "${DEPLOY_ROOT}/data"
  (
    eval "exec ${VERSIONS_LOCK_FD}>\"${VERSIONS_LOCK_FILE}\""
    flock "${VERSIONS_LOCK_FD}"
    "$@"
  )
}

versions_get() {
  local service="$1"
  _ensure_versions_file
  jq -r --arg s "$service" '.[$s].version_tag // ""' "$VERSIONS_FILE"
}

versions_get_blocked() {
  local service="$1"
  _ensure_versions_file
  jq -r --arg s "$service" '.[$s].blocked_version_tag // ""' "$VERSIONS_FILE"
}

versions_get_config_hash() {
  local service="$1"
  _ensure_versions_file
  jq -r --arg s "$service" '.[$s].config_hash // ""' "$VERSIONS_FILE"
}

versions_set_config_hash() {
  local service="$1" hash="$2"
  _with_versions_lock _versions_set_config_hash_inner "$service" "$hash"
}

_versions_set_config_hash_inner() {
  local service="$1" hash="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg s "$service" --arg h "$hash" \
    '.[$s] = ((.[$s] // {}) | .config_hash = $h)' \
    "$VERSIONS_FILE" >"$tmp"
  mv "$tmp" "$VERSIONS_FILE"
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
    '.[$s] = ((.[$s] // {}) | .version_tag = $t | del(.blocked_version_tag))' \
    "$VERSIONS_FILE" >"$tmp"
  mv "$tmp" "$VERSIONS_FILE"
}

versions_set_blocked() {
  local service="$1" tag="$2"
  _with_versions_lock _versions_set_blocked_inner "$service" "$tag"
}

_versions_set_blocked_inner() {
  local service="$1" tag="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg s "$service" --arg b "$tag" \
    '.[$s] = ((.[$s] // {}) | .blocked_version_tag = $b)' \
    "$VERSIONS_FILE" >"$tmp"
  mv "$tmp" "$VERSIONS_FILE"
}

versions_clear_blocked() {
  local service="$1"
  _with_versions_lock _versions_clear_blocked_inner "$service"
}

_versions_clear_blocked_inner() {
  local service="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg s "$service" \
    'if .[$s] then .[$s] |= del(.blocked_version_tag) else . end' \
    "$VERSIONS_FILE" >"$tmp"
  mv "$tmp" "$VERSIONS_FILE"
}

versions_ensure() {
  _with_versions_lock _versions_ensure_inner
}

_versions_ensure_inner() {
  local tmp merged name existing blocked config_hash
  tmp="$(mktemp)"
  merged="$(mktemp)"

  jq -n '{}' >"$merged"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    existing="$(jq -r --arg s "$name" '.[$s].version_tag // ""' "$VERSIONS_FILE" 2>/dev/null || echo "")"
    blocked="$(jq -r --arg s "$name" '.[$s].blocked_version_tag // empty' "$VERSIONS_FILE" 2>/dev/null || true)"
    config_hash="$(jq -r --arg s "$name" '.[$s].config_hash // empty' "$VERSIONS_FILE" 2>/dev/null || true)"
    if [[ -n "$blocked" && -n "$config_hash" ]]; then
      jq --arg s "$name" --arg t "$existing" --arg b "$blocked" --arg h "$config_hash" \
        '.[$s] = {version_tag: $t, blocked_version_tag: $b, config_hash: $h}' \
        "$merged" >"$tmp"
    elif [[ -n "$blocked" ]]; then
      jq --arg s "$name" --arg t "$existing" --arg b "$blocked" \
        '.[$s] = {version_tag: $t, blocked_version_tag: $b}' \
        "$merged" >"$tmp"
    elif [[ -n "$config_hash" ]]; then
      jq --arg s "$name" --arg t "$existing" --arg h "$config_hash" \
        '.[$s] = {version_tag: $t, config_hash: $h}' \
        "$merged" >"$tmp"
    else
      jq --arg s "$name" --arg t "$existing" \
        '.[$s] = {version_tag: $t}' \
        "$merged" >"$tmp"
    fi
    mv "$tmp" "$merged"
  done < <(service_names)

  mv "$merged" "$VERSIONS_FILE"
}

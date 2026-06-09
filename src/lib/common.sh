#!/usr/bin/env bash
# 所有 easy-deploy 脚本的公共引导

set -euo pipefail

if [[ -z "${DEPLOY_ROOT:-}" ]]; then
  DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

cd "$DEPLOY_ROOT"

CONFIG_FILE="${DEPLOY_ROOT}/easy-deploy-config.yaml"
VERSIONS_FILE="${DEPLOY_ROOT}/data/current-versions.json"
VERSIONS_LOCK_FILE="${DEPLOY_ROOT}/data/current-versions.lock"
LOCK_FILE="${DEPLOY_ROOT}/data/easy-deploy.lock"
TEMP_DIR="${DEPLOY_ROOT}/data/temp"
YQ_BIN="${YQ_BIN:-/usr/local/bin/yq}"

# 必须是 mikefarah/yq（Go 版），不能用 apt 的 Python 版 yq（kislyuk）
is_mikefarah_yq() {
  local bin="${1:-}"
  [[ -n "$bin" && -x "$bin" ]] || return 1
  "$bin" --version 2>&1 | grep -qi 'mikefarah/yq'
}

resolve_yq_bin() {
  local candidate
  if [[ -x "$YQ_BIN" ]] && is_mikefarah_yq "$YQ_BIN"; then
    export YQ_BIN
    return 0
  fi
  if [[ -x /usr/local/bin/yq ]] && is_mikefarah_yq /usr/local/bin/yq; then
    YQ_BIN=/usr/local/bin/yq
    export YQ_BIN
    return 0
  fi
  candidate="$(command -v yq 2>/dev/null || true)"
  if [[ -n "$candidate" ]] && is_mikefarah_yq "$candidate"; then
    YQ_BIN="$candidate"
    export YQ_BIN
    return 0
  fi
  return 1
}

install_mikefarah_yq() {
  local target="${1:-/usr/local/bin/yq}"
  local sudo_cmd="${2:-}"
  local arch yq_bin tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64) yq_bin=yq_linux_amd64 ;;
    aarch64|arm64) yq_bin=yq_linux_arm64 ;;
    *) die "不支持自动安装 yq 的架构: ${arch}" ;;
  esac
  tmp="$(mktemp)"
  curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/${yq_bin}" -o "$tmp"
  $sudo_cmd install -m 0755 "$tmp" "$target"
  rm -f "$tmp"
  YQ_BIN="$target"
  export YQ_BIN
}

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    date +%s%N-$RANDOM
  fi
}

log_msg() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  log_msg "错误: $*"
  exit 1
}

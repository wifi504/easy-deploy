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

# mikefarah/yq 发布包下载地址（apt 源里是 Python 版 kislyuk/yq，不能走包管理器）
yq_release_asset_name() {
  case "$(uname -m)" in
    x86_64) echo yq_linux_amd64 ;;
    aarch64|arm64) echo yq_linux_arm64 ;;
    *) die "不支持自动安装 yq 的架构: $(uname -m)" ;;
  esac
}

yq_default_download_url() {
  local asset="${1:-$(yq_release_asset_name)}"
  echo "https://github.com/mikefarah/yq/releases/latest/download/${asset}"
}

# 支持通过环境变量走镜像或内网源，避免直连 GitHub：
#   YQ_DOWNLOAD_URL   — 完整 URL，优先级最高（适合内网静态文件服务）
#   GITHUB_MIRROR     — 镜像前缀，拼在默认 URL 前，例如 https://ghfast.top
yq_resolve_download_url() {
  local asset="${1:-$(yq_release_asset_name)}"
  local default_url
  default_url="$(yq_default_download_url "$asset")"
  if [[ -n "${YQ_DOWNLOAD_URL:-}" ]]; then
    echo "$YQ_DOWNLOAD_URL"
  elif [[ -n "${GITHUB_MIRROR:-}" ]]; then
    echo "${GITHUB_MIRROR%/}/${default_url}"
  else
    echo "$default_url"
  fi
}

download_yq_binary() {
  local dest="$1"
  local asset url
  asset="$(yq_release_asset_name)"
  url="$(yq_resolve_download_url "$asset")"
  if ! curl -fsSL --connect-timeout 15 --max-time 300 "$url" -o "$dest"; then
    if [[ -z "${GITHUB_MIRROR:-}" && -z "${YQ_DOWNLOAD_URL:-}" ]]; then
      die "yq 下载失败（${url}）。可设置 GITHUB_MIRROR 或 YQ_DOWNLOAD_URL 使用镜像/内网源，例如: GITHUB_MIRROR=https://ghfast.top bash install.sh"
    fi
    die "yq 下载失败: ${url}"
  fi
}

install_mikefarah_yq() {
  local target="${1:-/usr/local/bin/yq}"
  local sudo_cmd="${2:-}"
  local tmp
  tmp="$(mktemp)"
  download_yq_binary "$tmp"
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

#!/usr/bin/env bash
# 安装 easy-deploy 运行依赖

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_ROOT"

log() {
  echo "[install] $*"
}

if [[ "$(id -u)" -ne 0 ]]; then
  log "警告: 未以 root 运行，安装系统包可能需要 sudo"
  SUDO="sudo"
else
  SUDO=""
fi

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo apt
  elif command -v dnf >/dev/null 2>&1; then
    echo dnf
  elif command -v yum >/dev/null 2>&1; then
    echo yum
  else
    echo unknown
  fi
}

install_packages_apt() {
  $SUDO apt-get update
  $SUDO apt-get install -y curl jq unzip tar p7zip-full
  if ! command -v yq >/dev/null 2>&1; then
    $SUDO apt-get install -y yq || {
      log "从 GitHub 安装 yq..."
      local arch yq_bin
      arch="$(uname -m)"
      case "$arch" in
        x86_64) yq_bin=yq_linux_amd64 ;;
        aarch64|arm64) yq_bin=yq_linux_arm64 ;;
        *) log "不支持自动安装 yq 的架构: ${arch}"; return 1 ;;
      esac
      curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/${yq_bin}" -o /tmp/yq
      $SUDO install -m 0755 /tmp/yq /usr/local/bin/yq
    }
  fi
}

install_packages_yum() {
  local mgr="$1"
  $SUDO "$mgr" install -y curl jq unzip tar p7zip p7zip-plugins
  if ! command -v yq >/dev/null 2>&1; then
    log "从 GitHub 安装 yq..."
    local arch yq_bin
    arch="$(uname -m)"
    case "$arch" in
      x86_64) yq_bin=yq_linux_amd64 ;;
      aarch64|arm64) yq_bin=yq_linux_arm64 ;;
      *) log "不支持自动安装 yq 的架构: ${arch}"; return 1 ;;
    esac
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/${yq_bin}" -o /tmp/yq
    $SUDO install -m 0755 /tmp/yq /usr/local/bin/yq
  fi
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "未安装 docker"
    log "请参考安装: https://docs.docker.com/engine/install/"
    return 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    log "docker compose (V2 插件) 不可用"
    log "请参考安装: https://docs.docker.com/compose/install/linux/"
    return 1
  fi
  log "docker 与 docker compose 已就绪"
  return 0
}

EASY_DEPLOY_CMD="/usr/local/bin/easy-deploy"

register_command() {
  local target="${DEPLOY_ROOT}/easy-deploy.sh"
  chmod +x "$target" "${DEPLOY_ROOT}/install.sh" "${DEPLOY_ROOT}/uninstall.sh"
  chmod +x "${DEPLOY_ROOT}/scripts/"*.sh
  $SUDO ln -sf "$target" "$EASY_DEPLOY_CMD"
  log "已注册命令 easy-deploy -> ${target}"
}

mkdir -p "${DEPLOY_ROOT}/data/temp" "${DEPLOY_ROOT}/logs"
log "已创建 data/ 与 logs/ 目录"

pkg_mgr="$(detect_pkg_manager)"
case "$pkg_mgr" in
  apt) install_packages_apt ;;
  dnf) install_packages_yum dnf ;;
  yum) install_packages_yum yum ;;
  *)
    log "不支持的包管理器，请手动安装: curl jq yq unzip tar 7z"
    exit 1
    ;;
esac

log "脚本依赖已安装"

check_docker || true

register_command

log "完成。请配置 easy-deploy-config.yaml 后运行 easy-deploy"

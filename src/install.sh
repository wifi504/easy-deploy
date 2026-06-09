#!/usr/bin/env bash
# 安装 easy-deploy 运行依赖

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_ROOT"

INSTALL_INFO="${DEPLOY_ROOT}/install.info"
YQ_TARGET="/usr/local/bin/yq"

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"

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

is_apt_pkg_installed() {
  dpkg -l "$1" 2>/dev/null | grep -q '^ii'
}

is_yum_pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

# 安装前写入 install.info，记录原本就有的依赖（仅首次创建，不覆盖）
record_preexisting_deps() {
  if [[ -f "$INSTALL_INFO" ]]; then
    log "install.info 已存在，跳过记录"
    return 0
  fi

  local mgr="$1"
  {
    echo "pkg_mgr=${mgr}"
    case "$mgr" in
      apt)
        local pkg
        for pkg in curl jq unzip tar p7zip-full; do
          if is_apt_pkg_installed "$pkg"; then
            echo "preexisting_pkg=${pkg}"
          fi
        done
        # Python 版 yq 若已通过 apt 安装，卸载时不应误删
        if is_apt_pkg_installed yq; then
          echo "preexisting_pkg=yq"
        fi
        ;;
      dnf|yum)
        local pkg
        for pkg in curl jq unzip tar p7zip; do
          if is_yum_pkg_installed "$pkg"; then
            echo "preexisting_pkg=${pkg}"
          fi
        done
        if is_yum_pkg_installed yq; then
          echo "preexisting_pkg=yq"
        fi
        ;;
    esac
    if [[ -x "$YQ_TARGET" ]] && is_mikefarah_yq "$YQ_TARGET"; then
      echo "preexisting_yq_local=1"
    fi
  } >"$INSTALL_INFO"

  log "已写入 install.info（记录安装前已存在的依赖）"
}

mark_installed_yq_local() {
  [[ -f "$INSTALL_INFO" ]] || return 0
  if grep -qx 'preexisting_yq_local=1' "$INSTALL_INFO"; then
    return 0
  fi
  if ! grep -qx 'installed_yq_local=1' "$INSTALL_INFO"; then
    echo "installed_yq_local=1" >>"$INSTALL_INFO"
  fi
}

try_install_yq_from_dnf() {
  local mgr="$1"
  local candidate
  # Fedora 等发行版的 yq 包是 mikefarah/yq；CentOS EPEL 多为 Python 版，装完会校验并放弃
  if ! $SUDO "$mgr" install -y yq >/dev/null 2>&1; then
    return 1
  fi
  candidate="$(command -v yq 2>/dev/null || true)"
  [[ -n "$candidate" ]] && is_mikefarah_yq "$candidate"
}

ensure_mikefarah_yq() {
  local existing=""

  if [[ -x "$YQ_TARGET" ]] && is_mikefarah_yq "$YQ_TARGET"; then
    log "mikefarah/yq 已就绪: ${YQ_TARGET}"
    return 0
  fi

  existing="$(command -v yq 2>/dev/null || true)"
  if [[ -n "$existing" ]] && is_mikefarah_yq "$existing"; then
    log "mikefarah/yq 已就绪: ${existing}"
    return 0
  fi

  if command -v yq >/dev/null 2>&1 && ! is_mikefarah_yq "$(command -v yq)"; then
    log "检测到 Python 版 yq（kislyuk），easy-deploy 需要 mikefarah/yq"
  fi

  case "$pkg_mgr" in
    dnf|yum)
      if try_install_yq_from_dnf "$pkg_mgr"; then
        log "已通过 ${pkg_mgr} 安装 mikefarah/yq: $(command -v yq)"
        return 0
      fi
      ;;
  esac

  if [[ -n "${YQ_DOWNLOAD_URL:-}" ]]; then
    log "从自定义地址安装 mikefarah/yq 到 ${YQ_TARGET}..."
  elif [[ -n "${GITHUB_MIRROR:-}" ]]; then
    log "通过镜像 ${GITHUB_MIRROR} 安装 mikefarah/yq 到 ${YQ_TARGET}..."
  else
    log "下载 mikefarah/yq 到 ${YQ_TARGET}（apt 源无此包，需拉取二进制；慢可设 GITHUB_MIRROR）..."
  fi
  install_mikefarah_yq "$YQ_TARGET" "$SUDO"
  mark_installed_yq_local
  log "mikefarah/yq 安装完成"
}

install_packages_apt() {
  $SUDO apt-get update
  $SUDO apt-get install -y curl jq unzip tar p7zip-full
}

install_packages_yum() {
  local mgr="$1"
  $SUDO "$mgr" install -y curl jq unzip tar p7zip p7zip-plugins
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
  apt|dnf|yum) ;;
  *)
    log "不支持的包管理器，请手动安装: curl jq unzip tar 7z，并安装 mikefarah/yq"
    exit 1
    ;;
esac

record_preexisting_deps "$pkg_mgr"

case "$pkg_mgr" in
  apt) install_packages_apt ;;
  dnf) install_packages_yum dnf ;;
  yum) install_packages_yum yum ;;
esac

ensure_mikefarah_yq

log "脚本依赖已安装"

check_docker || true

register_command

log "完成。请配置 easy-deploy-config.yaml 后运行 easy-deploy"

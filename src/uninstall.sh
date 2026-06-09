#!/usr/bin/env bash
# 逐项确认后卸载依赖与运行时数据

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_INFO="${DEPLOY_ROOT}/install.info"

ask_yn() {
  local prompt="$1"
  local reply
  read -r -p "${prompt} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

EASY_DEPLOY_CMD="/usr/local/bin/easy-deploy"

is_preexisting_pkg() {
  local pkg="$1"
  [[ -f "$INSTALL_INFO" ]] && grep -qx "preexisting_pkg=${pkg}" "$INSTALL_INFO"
}

is_preexisting_yq_local() {
  [[ -f "$INSTALL_INFO" ]] && grep -qx 'preexisting_yq_local=1' "$INSTALL_INFO"
}

is_installed_yq_local() {
  [[ -f "$INSTALL_INFO" ]] && grep -qx 'installed_yq_local=1' "$INSTALL_INFO"
}

unregister_command() {
  if [[ ! -e "$EASY_DEPLOY_CMD" && ! -L "$EASY_DEPLOY_CMD" ]]; then
    echo "easy-deploy 命令未注册，跳过"
    return 0
  fi

  if [[ -L "$EASY_DEPLOY_CMD" ]]; then
    local link_target current_target
    link_target="$(readlink -f "$EASY_DEPLOY_CMD" 2>/dev/null || readlink "$EASY_DEPLOY_CMD")"
    current_target="$(readlink -f "${DEPLOY_ROOT}/easy-deploy.sh")"
    if [[ "$link_target" == "$current_target" ]]; then
      $SUDO rm -f "$EASY_DEPLOY_CMD"
      echo "已取消注册 easy-deploy 命令"
      return 0
    fi
    echo "跳过：${EASY_DEPLOY_CMD} 指向 ${link_target}，不是本目录的安装"
    return 0
  fi

  echo "跳过：${EASY_DEPLOY_CMD} 存在但不是 symlink"
}

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

remove_apt() {
  local pkg="$1"
  if is_preexisting_pkg "$pkg"; then
    echo "跳过 apt 包 ${pkg}（install.info：安装前已存在）"
    return 0
  fi
  if dpkg -l "$pkg" >/dev/null 2>&1; then
    if ask_yn "是否卸载 apt 包 ${pkg}?"; then
      $SUDO apt-get remove -y "$pkg"
    fi
  fi
}

remove_yum() {
  local mgr="$1" pkg="$2"
  if is_preexisting_pkg "$pkg"; then
    echo "跳过 ${mgr} 包 ${pkg}（install.info：安装前已存在）"
    return 0
  fi
  if rpm -q "$pkg" >/dev/null 2>&1; then
    if ask_yn "是否卸载 ${mgr} 包 ${pkg}?"; then
      $SUDO "$mgr" remove -y "$pkg"
    fi
  fi
}

echo "easy-deploy 卸载助手（每项均需确认）"

unregister_command

pkg_mgr="$(detect_pkg_manager)"
case "$pkg_mgr" in
  apt)
    remove_apt curl
    remove_apt jq
    remove_apt yq
    remove_apt unzip
    remove_apt tar
    remove_apt p7zip-full
    ;;
  dnf|yum)
    remove_yum "$pkg_mgr" curl
    remove_yum "$pkg_mgr" jq
    remove_yum "$pkg_mgr" yq
    remove_yum "$pkg_mgr" unzip
    remove_yum "$pkg_mgr" tar
    remove_yum "$pkg_mgr" p7zip
    ;;
  *)
    echo "未知包管理器，跳过系统包卸载"
    ;;
esac

if [[ -f /usr/local/bin/yq ]]; then
  if is_preexisting_yq_local; then
    echo "跳过 /usr/local/bin/yq（install.info：安装前已存在）"
  elif is_installed_yq_local; then
    if ask_yn "是否删除 /usr/local/bin/yq（install.sh 安装的 mikefarah/yq）?"; then
      $SUDO rm -f /usr/local/bin/yq
    fi
  else
    echo "跳过 /usr/local/bin/yq（非 install.sh 安装，请自行处理）"
  fi
fi

if ask_yn "是否删除 easy-deploy 运行时数据（data/、logs/）?"; then
  rm -rf "${DEPLOY_ROOT}/data/easy-deploy.lock" \
    "${DEPLOY_ROOT}/data/current-versions.lock" \
    "${DEPLOY_ROOT}/data/current-versions.json" \
    "${DEPLOY_ROOT}/data/temp/"* \
    "${DEPLOY_ROOT}/logs/"
  mkdir -p "${DEPLOY_ROOT}/data/temp"
  echo "运行时数据已删除"
fi

rm -f "$INSTALL_INFO"

echo "卸载助手执行完毕"

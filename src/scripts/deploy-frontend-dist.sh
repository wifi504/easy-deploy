#!/usr/bin/env bash
# 前端静态资源：解压、覆盖 target、更新版本、重载 Nginx

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPLOY_ROOT

if [[ $# -ne 3 ]]; then
  echo "用法: deploy-frontend-dist.sh <serviceName> <tempFile> <version>" >&2
  exit 1
fi

SERVICE_NAME="$1"
temp_file="$2"
version="$3"
export hook_service_name="$SERVICE_NAME"

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"
# shellcheck source=lib/versions.sh
source "${DEPLOY_ROOT}/lib/versions.sh"
# shellcheck source=lib/hooks.sh
source "${DEPLOY_ROOT}/lib/hooks.sh"

log_deploy() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

_fail_deploy() {
  export hook_deploy_errmsg="$1"
  run_hook on-deploy-fail
  log_deploy "$1"
  cleanup_on_fail
  exit 1
}

target="$(service_deploy_field "$SERVICE_NAME" target)"
temp_file_dir="$(dirname "$temp_file")"
extract_uuid="$(new_uuid)"
extract_dir="${TEMP_DIR}/${extract_uuid}"

# 失败时清理本次使用的临时目录
cleanup_on_fail() {
  rm -rf "$temp_file_dir" "$extract_dir"
}

run_hook on-deploy-start

mkdir -p "$extract_dir"

basename_file="$(basename "$temp_file")"
log_deploy "解压 ${temp_file} 到 ${extract_dir}"

extract_ok=0
if [[ "$basename_file" == *.zip ]]; then
  unzip -q "$temp_file" -d "$extract_dir" && extract_ok=1
elif [[ "$basename_file" == *.7z ]]; then
  7z x "$temp_file" -o"$extract_dir" -y >/dev/null && extract_ok=1
elif [[ "$basename_file" == *.tar.gz || "$basename_file" == *.tgz ]]; then
  tar -xzf "$temp_file" -C "$extract_dir" && extract_ok=1
else
  _fail_deploy "不支持的压缩格式: ${basename_file}"
fi

if [[ "$extract_ok" -ne 1 ]]; then
  _fail_deploy "解压失败"
fi

shopt -s nullglob dotglob
extract_items=("$extract_dir"/*)
shopt -u nullglob dotglob

if [[ ${#extract_items[@]} -eq 0 ]]; then
  _fail_deploy "解压目录为空"
fi

log_deploy "清空目标目录: ${target}"
if ! find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; then
  _fail_deploy "清空目标目录失败"
fi

log_deploy "移动文件到 ${target}"
shopt -s dotglob
if ! mv "$extract_dir"/* "$target"/; then
  shopt -u dotglob
  _fail_deploy "移动文件到目标目录失败"
fi
shopt -u dotglob

rm -rf "$temp_file_dir" "$extract_dir"

versions_set "$SERVICE_NAME" "$version"
log_deploy "已更新 version_tag 为 ${version}"

reload_cmd="$(reload_nginx_cmd)"
log_deploy "重载 Nginx: ${reload_cmd}"
if ! eval "$reload_cmd"; then
  export hook_deploy_errmsg="Nginx 重载失败"
  run_hook on-deploy-fail
  log_deploy "Nginx 重载失败"
  exit 1
fi

run_hook on-deploy-success
log_deploy "service ${SERVICE_NAME} 前端部署完成"

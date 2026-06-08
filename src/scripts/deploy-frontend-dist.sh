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

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"
# shellcheck source=lib/versions.sh
source "${DEPLOY_ROOT}/lib/versions.sh"

log_deploy() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

target="$(service_deploy_field "$SERVICE_NAME" target)"
temp_file_dir="$(dirname "$temp_file")"
extract_uuid="$(new_uuid)"
extract_dir="${TEMP_DIR}/${extract_uuid}"

# 失败时清理本次使用的临时目录
cleanup_on_fail() {
  rm -rf "$temp_file_dir" "$extract_dir"
}

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
  log_deploy "不支持的压缩格式: ${basename_file}"
  cleanup_on_fail
  exit 1
fi

if [[ "$extract_ok" -ne 1 ]]; then
  log_deploy "解压失败"
  cleanup_on_fail
  exit 1
fi

shopt -s nullglob dotglob
extract_items=("$extract_dir"/*)
shopt -u nullglob dotglob

if [[ ${#extract_items[@]} -eq 0 ]]; then
  log_deploy "解压目录为空"
  cleanup_on_fail
  exit 1
fi

log_deploy "清空目标目录: ${target}"
if ! find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; then
  log_deploy "清空目标目录失败"
  cleanup_on_fail
  exit 1
fi

log_deploy "移动文件到 ${target}"
shopt -s dotglob
if ! mv "$extract_dir"/* "$target"/; then
  shopt -u dotglob
  log_deploy "移动文件到目标目录失败"
  cleanup_on_fail
  exit 1
fi
shopt -u dotglob

rm -rf "$temp_file_dir" "$extract_dir"

versions_set "$SERVICE_NAME" "$version"
log_deploy "已更新 version_tag 为 ${version}"

reload_cmd="$(reload_nginx_cmd)"
log_deploy "重载 Nginx: ${reload_cmd}"
eval "$reload_cmd"

log_deploy "service ${SERVICE_NAME} 前端部署完成"

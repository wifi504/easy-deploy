#!/usr/bin/env bash
# Gitea generic 制品：查最新版本并下载

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPLOY_ROOT

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "用法: package-generic.sh <serviceName> [force]" >&2
  exit 1
fi

SERVICE_NAME="$1"
export hook_service_name="$SERVICE_NAME"
FORCE=0
if [[ $# -eq 2 && ( "$2" == "force" || "$2" == "--force" ) ]]; then
  FORCE=1
fi

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"
# shellcheck source=lib/versions.sh
source "${DEPLOY_ROOT}/lib/versions.sh"
# shellcheck source=lib/hooks.sh
source "${DEPLOY_ROOT}/lib/hooks.sh"

log_pkg() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

_fail_package() {
  export hook_package_errmsg="$1"
  run_hook on-package-fail
  log_pkg "$1"
  exit 1
}

owner="$(service_package_field "$SERVICE_NAME" owner)"
pkg_name="$(service_package_field "$SERVICE_NAME" name)"
pkg_file="$(service_package_field "$SERVICE_NAME" file)"
token="$(gitea_token)"
base_url="$(gitea_url)"

run_hook on-package-start

latest_url="${base_url}/api/v1/packages/${owner}/generic/${pkg_name}/-/latest"
log_pkg "查询最新版本: ${latest_url}"

latest_json="$(curl -sf -H "Authorization: token ${token}" "$latest_url")" || \
  _fail_package "获取 Gitea 最新版本失败"

version="$(echo "$latest_json" | jq -r '.version // empty')"
if [[ -z "$version" ]]; then
  _fail_package "无法从 Gitea 响应中提取 version"
fi

current="$(versions_get "$SERVICE_NAME")"
if [[ "$FORCE" -eq 0 && "$version" == "$current" ]]; then
  log_pkg "版本未变 (${version})，跳过部署"
  run_hook on-package-skip
  echo "skip_deploy"
  exit 0
fi

if [[ "$FORCE" -eq 1 && "$version" == "$current" ]]; then
  log_pkg "配置已变更，强制重新下载版本 ${version}"
fi

download_url="${base_url}/api/packages/${owner}/generic/${pkg_name}/${version}/${pkg_file}"
temp_uuid="$(new_uuid)"
dest_dir="${TEMP_DIR}/${temp_uuid}"
mkdir -p "$dest_dir"
dest_file="${dest_dir}/${pkg_file}"

log_pkg "下载制品: ${download_url} -> ${dest_file}"
curl -sf -H "Authorization: token ${token}" -o "$dest_file" "$download_url" || {
  rm -rf "$dest_dir"
  _fail_package "下载制品文件失败"
}

log_pkg "已下载版本 ${version}"
export hook_package_version_tag="$version"
run_hook on-package-success
echo "$version"
echo "$dest_file"

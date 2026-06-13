#!/usr/bin/env bash
# Gitea 容器镜像：docker pull 并清理旧镜像

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPLOY_ROOT

if [[ $# -ne 1 ]]; then
  echo "用法: package-docker-container.sh <serviceName>" >&2
  exit 1
fi

SERVICE_NAME="$1"
export hook_service_name="$SERVICE_NAME"

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
host="$(gitea_host)"
image_ref="${host}/${owner}/${pkg_name}:latest"
repo_prefix="${host}/${owner}/${pkg_name}"

run_hook on-package-start

log_pkg "拉取镜像: ${image_ref}"
pull_output="$(docker pull "$image_ref" 2>&1)" || {
  echo "$pull_output" >&2
  _fail_package "docker pull 失败"
}
echo "$pull_output" >&2

digest="$(echo "$pull_output" | sed -n 's/^Digest: \(sha256:[a-f0-9]*\).*/\1/p' | tail -1)"
if [[ -z "$digest" ]]; then
  digest="$(docker inspect --format='{{index .RepoDigests 0}}' "$image_ref" 2>/dev/null || true)"
  digest="${digest#*@}"
fi

if [[ -z "$digest" || "$digest" != sha256:* ]]; then
  _fail_package "无法确定镜像 Digest"
fi

current="$(versions_get "$SERVICE_NAME")"
if [[ "$digest" == "$current" ]]; then
  log_pkg "Digest 未变 (${digest})，跳过部署"
  run_hook on-package-skip
  echo "skip_deploy"
  exit 0
fi

blocked="$(versions_get_blocked "$SERVICE_NAME")"
if [[ -n "$blocked" && "$digest" == "$blocked" ]]; then
  log_pkg "Digest 为已知失败版本 (${digest})，视为无新版本，跳过部署"
  run_hook on-package-skip
  echo "skip_deploy"
  exit 0
fi

keep_new_id="$(docker inspect --format='{{.Id}}' "${repo_prefix}@${digest}" 2>/dev/null || true)"
keep_old_id=""
if [[ -n "$current" ]]; then
  keep_old_id="$(docker inspect --format='{{.Id}}' "${repo_prefix}@${current}" 2>/dev/null || true)"
fi

mapfile -t repo_image_ids < <(docker images -q --no-trunc "${repo_prefix}" 2>/dev/null || true)
for img_id in "${repo_image_ids[@]}"; do
  [[ -z "$img_id" ]] && continue
  if [[ -n "$keep_new_id" && "$img_id" == "$keep_new_id" ]]; then
    continue
  fi
  if [[ -n "$keep_old_id" && "$img_id" == "$keep_old_id" ]]; then
    continue
  fi
  log_pkg "删除旧镜像: ${img_id}"
  docker rmi -f "$img_id" >/dev/null 2>&1 || true
done

log_pkg "新 Digest: ${digest}"
export hook_package_version_tag="$digest"
run_hook on-package-success
echo "$digest"

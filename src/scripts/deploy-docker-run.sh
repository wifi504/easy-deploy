#!/usr/bin/env bash
# Docker Run：停止旧容器、启动新镜像、健康检查、失败回滚

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPLOY_ROOT

if [[ $# -ne 2 ]]; then
  echo "用法: deploy-docker-run.sh <serviceName> <imageDigest>" >&2
  exit 1
fi

SERVICE_NAME="$1"
image_digest="$2"
export hook_service_name="$SERVICE_NAME"
export hook_package_version_tag="$image_digest"

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"
# shellcheck source=lib/versions.sh
source "${DEPLOY_ROOT}/lib/versions.sh"
# shellcheck source=lib/hooks.sh
source "${DEPLOY_ROOT}/lib/hooks.sh"
# shellcheck source=lib/deploy-docker.sh
source "${DEPLOY_ROOT}/lib/deploy-docker.sh"

log_deploy() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

owner="$(service_package_field "$SERVICE_NAME" owner)"
pkg_name="$(service_package_field "$SERVICE_NAME" name)"
host="$(gitea_host)"
check_seconds="$(service_deploy_field "$SERVICE_NAME" started-check-seconds)"
image_ref="${host}/${owner}/${pkg_name}@${image_digest}"

old_version="$(versions_get "$SERVICE_NAME")"

declare -a deploy_opts=() deploy_cmd=() deploy_args=()
read_deploy_argv_field "$SERVICE_NAME" options deploy_opts
read_deploy_argv_field "$SERVICE_NAME" command deploy_cmd
read_deploy_argv_field "$SERVICE_NAME" args deploy_args
dedupe_d_flag deploy_opts

container_name="$(parse_container_name_from_argv "${deploy_opts[@]}")"

docker_run_with_digest() {
  local digest="$1"
  local ref="${host}/${owner}/${pkg_name}@${digest}"
  local -a cmd=(docker run -d)
  cmd+=("${deploy_opts[@]}")
  cmd+=("$ref")
  [[ ${#deploy_cmd[@]} -gt 0 ]] && cmd+=("${deploy_cmd[@]}")
  [[ ${#deploy_args[@]} -gt 0 ]] && cmd+=("${deploy_args[@]}")
  log_deploy "执行: docker run -d ... ${ref}"
  "${cmd[@]}"
}

rollback() {
  log_deploy "回滚容器 ${container_name}"
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  if [[ -n "$old_version" ]]; then
    log_deploy "用旧 digest 重新启动: ${old_version}"
    if ! docker_run_with_digest "$old_version"; then
      log_deploy "警告: 回滚启动旧版本失败"
    fi
  fi
  remove_image_by_digest "$host" "$owner" "$pkg_name" "$image_digest"
}

_fail_deploy() {
  export hook_deploy_errmsg="$1"
  run_hook on-deploy-fail
  log_deploy "$1"
  rollback
  exit 1
}

run_hook on-deploy-start

log_deploy "停止并删除旧容器: ${container_name}"
docker rm -f "$container_name" >/dev/null 2>&1 || true

log_deploy "启动新镜像: ${image_ref}"
if ! docker_run_with_digest "$image_digest"; then
  _fail_deploy "docker run 失败"
fi

if ! container_id="$(docker inspect --format='{{.Id}}' "$container_name" 2>/dev/null)"; then
  _fail_deploy "找不到容器 ${container_name}"
fi

if [[ "$check_seconds" == "-1" ]]; then
  log_deploy "已跳过稳定性检查 (started-check-seconds=-1)"
else
  log_deploy "等待 ${check_seconds} 秒进行稳定性检查"
  stability_err=""
  if ! stability_err="$(container_stability_check "$container_id" "$check_seconds")"; then
    _fail_deploy "$stability_err"
  fi
fi

versions_set "$SERVICE_NAME" "$image_digest"
remove_image_by_digest "$host" "$owner" "$pkg_name" "$old_version"

run_hook on-deploy-success
log_deploy "service ${SERVICE_NAME} docker run 部署完成"

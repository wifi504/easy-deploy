#!/usr/bin/env bash
# Docker Run：多容器顺序部署、健康检查、失败全量回滚

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

old_version="$(versions_get "$SERVICE_NAME")"
container_count="$(docker_run_container_count "$SERVICE_NAME")"

docker_run_with_digest() {
  local digest="$1"
  local -n _opts="$2"
  local -n _cmd="$3"
  local -n _args="$4"
  local ref="${host}/${owner}/${pkg_name}@${digest}"
  local -a cmd=(docker run -d)
  cmd+=("${_opts[@]}")
  cmd+=("$ref")
  [[ ${#_cmd[@]} -gt 0 ]] && cmd+=("${_cmd[@]}")
  [[ ${#_args[@]} -gt 0 ]] && cmd+=("${_args[@]}")
  log_deploy "执行: docker run -d ... ${ref}"
  "${cmd[@]}"
}

container_name_at_index() {
  local index="$1"
  local -a opts=()
  read_container_argv_field "$SERVICE_NAME" "$index" options opts
  dedupe_d_flag opts
  parse_container_name_from_argv "${opts[@]}"
}

remove_all_service_containers() {
  local i name
  for ((i = 0; i < container_count; i++)); do
    name="$(container_name_at_index "$i")"
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
}

restart_all_containers_with_digest() {
  local digest="$1"
  local i
  local -a opts=() cmd=() args=()
  for ((i = 0; i < container_count; i++)); do
    opts=()
    cmd=()
    args=()
    read_container_argv_field "$SERVICE_NAME" "$i" options opts
    read_container_argv_field "$SERVICE_NAME" "$i" command cmd
    read_container_argv_field "$SERVICE_NAME" "$i" args args
    dedupe_d_flag opts
    if ! docker_run_with_digest "$digest" opts cmd args; then
      log_deploy "警告: 容器实例 ${i} 启动失败"
      return 1
    fi
  done
  return 0
}

rollback_all() {
  log_deploy "回滚全部容器"
  remove_all_service_containers
  if [[ -n "$old_version" ]]; then
    log_deploy "用旧 digest 重新启动全部容器: ${old_version}"
    restart_all_containers_with_digest "$old_version" || true
  fi
  remove_image_by_digest "$host" "$owner" "$pkg_name" "$image_digest"
}

_fail_deploy() {
  export hook_deploy_errmsg="$1"
  run_hook on-deploy-fail
  log_deploy "$1"
  rollback_all
  exit 1
}

run_hook on-deploy-start

for ((container_index = 0; container_index < container_count; container_index++)); do
  declare -a deploy_opts=() deploy_cmd=() deploy_args=()
  read_container_argv_field "$SERVICE_NAME" "$container_index" options deploy_opts
  read_container_argv_field "$SERVICE_NAME" "$container_index" command deploy_cmd
  read_container_argv_field "$SERVICE_NAME" "$container_index" args deploy_args
  dedupe_d_flag deploy_opts

  container_name="$(parse_container_name_from_argv "${deploy_opts[@]}")"
  image_ref="${host}/${owner}/${pkg_name}@${image_digest}"

  log_deploy "部署容器 [${container_index}/${container_count}]: ${container_name}"
  log_deploy "停止并删除旧容器: ${container_name}"
  docker rm -f "$container_name" >/dev/null 2>&1 || true

  log_deploy "启动新镜像: ${image_ref}"
  if ! docker_run_with_digest "$image_digest" deploy_opts deploy_cmd deploy_args; then
    _fail_deploy "容器 ${container_name} docker run 失败"
  fi

  if ! container_id="$(docker inspect --format='{{.Id}}' "$container_name" 2>/dev/null)"; then
    _fail_deploy "找不到容器 ${container_name}"
  fi

  if [[ "$check_seconds" == "-1" ]]; then
    log_deploy "已跳过稳定性检查 (started-check-seconds=-1)"
  else
    log_deploy "等待 ${check_seconds} 秒进行稳定性检查 (${container_name})"
    stability_err=""
    if ! stability_err="$(container_stability_check "$container_id" "$check_seconds")"; then
      _fail_deploy "容器 ${container_name}: ${stability_err}"
    fi
  fi
done

versions_set "$SERVICE_NAME" "$image_digest"
remove_image_by_digest "$host" "$owner" "$pkg_name" "$old_version"

run_hook on-deploy-success
log_deploy "service ${SERVICE_NAME} docker run 部署完成（${container_count} 个容器）"

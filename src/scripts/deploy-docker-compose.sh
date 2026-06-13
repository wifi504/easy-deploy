#!/usr/bin/env bash
# Docker Compose 单 service 部署：flock compose 文件 + patch + up + 稳定性 + 回滚

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPLOY_ROOT

if [[ $# -ne 2 ]]; then
  echo "用法: deploy-docker-compose.sh <serviceName> <imageDigest>" >&2
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

compose_file="$(service_deploy_field "$SERVICE_NAME" compose)"
compose_service="$(service_deploy_field "$SERVICE_NAME" service)"
check_seconds="$(service_deploy_field "$SERVICE_NAME" started-check-seconds)"
owner="$(service_package_field "$SERVICE_NAME" owner)"
pkg_name="$(service_package_field "$SERVICE_NAME" name)"
host="$(gitea_host)"
image_ref="${host}/${owner}/${pkg_name}@${image_digest}"

compose_lock="${compose_file}.easy-deploy.lock"
backup_file="${compose_file}.easy-deploy.bak"
COMPOSE_LOCK_FD=210

rollback_compose_service() {
  log_deploy "回滚 compose 服务 ${compose_service}"
  cp "$backup_file" "$compose_file"
  docker compose -f "$compose_file" up -d --no-deps --force-recreate "$compose_service" || true
  remove_image_by_digest "$host" "$owner" "$pkg_name" "$image_digest"
}

_fail_compose_deploy() {
  local errmsg="$1"
  rollback_compose_service
  rm -f "$backup_file"
  export hook_deploy_errmsg="$errmsg"
  run_hook on-deploy-fail
  versions_set_blocked "$SERVICE_NAME" "$image_digest"
  log_deploy "$errmsg"
  exit 1
}

run_hook on-deploy-start

old_version="$(versions_get "$SERVICE_NAME")"

eval "exec ${COMPOSE_LOCK_FD}>\"${compose_lock}\""
flock "${COMPOSE_LOCK_FD}"

cp "$compose_file" "$backup_file"

log_deploy "更新 compose 服务 ${compose_service} 的 image 为 ${image_ref}"
"$YQ_BIN" eval -i ".services[\"${compose_service}\"].image = \"${image_ref}\"" "$compose_file"

log_deploy "执行: docker compose up -d --no-deps --force-recreate ${compose_service}"
if ! docker compose -f "$compose_file" up -d --no-deps --force-recreate "$compose_service"; then
  _fail_compose_deploy "docker compose up 失败"
fi

container_id="$(docker compose -f "$compose_file" ps -q "$compose_service")"
if [[ -z "$container_id" ]]; then
  _fail_compose_deploy "找不到 service ${compose_service} 对应的容器"
fi

if [[ "$check_seconds" != "-1" ]]; then
  log_deploy "等待 ${check_seconds} 秒进行稳定性检查 (${compose_service})"
  stability_err=""
  if ! stability_err="$(container_stability_check "$container_id" "$check_seconds")"; then
    _fail_compose_deploy "${stability_err}"
  fi
else
  log_deploy "已跳过稳定性检查 (started-check-seconds=-1)"
fi

versions_set "$SERVICE_NAME" "$image_digest"
remove_image_by_digest "$host" "$owner" "$pkg_name" "$old_version"
rm -f "$backup_file"

run_hook on-deploy-success
touch "${LOG_DIR}/.deploy-executed"
log_deploy "service ${SERVICE_NAME} compose deploy 成功"
exit 0

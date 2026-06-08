#!/usr/bin/env bash
# Docker Compose：改 image、重启、健康检查、失败回滚

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPLOY_ROOT

if [[ $# -ne 2 ]]; then
  echo "用法: deploy-docker-compose.sh <serviceName> <imageDigest>" >&2
  exit 1
fi

SERVICE_NAME="$1"
image_digest="$2"

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"
# shellcheck source=lib/versions.sh
source "${DEPLOY_ROOT}/lib/versions.sh"

log_deploy() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

owner="$(service_package_field "$SERVICE_NAME" owner)"
pkg_name="$(service_package_field "$SERVICE_NAME" name)"
host="$(gitea_host)"
compose_file="$(service_deploy_field "$SERVICE_NAME" compose)"
compose_service="$(service_deploy_field "$SERVICE_NAME" service)"
check_seconds="$(service_deploy_field "$SERVICE_NAME" started-check-seconds)"
image_ref="${host}/${owner}/${pkg_name}@${image_digest}"

old_version="$(versions_get "$SERVICE_NAME")"
backup_file="${compose_file}.easy-deploy.bak"

cp "$compose_file" "$backup_file"

restore_compose() {
  cp "$backup_file" "$compose_file"
}

compose_down_up() {
  docker compose -f "$compose_file" down
  docker compose -f "$compose_file" up -d
}

remove_image_by_digest() {
  local digest="$1"
  [[ -z "$digest" ]] && return 0
  docker rmi -f "${host}/${owner}/${pkg_name}@${digest}" >/dev/null 2>&1 || true
}

rollback() {
  log_deploy "回滚 compose 文件并重新启动"
  restore_compose
  compose_down_up
  remove_image_by_digest "$image_digest"
}

log_deploy "更新 compose 服务 ${compose_service} 的 image 为 ${image_ref}"
yq eval -i ".services[\"${compose_service}\"].image = \"${image_ref}\"" "$compose_file"

log_deploy "重启 compose: ${compose_file}"
if ! compose_down_up; then
  log_deploy "docker compose down/up 失败"
  rollback
  rm -f "$backup_file"
  exit 1
fi

container_id="$(docker compose -f "$compose_file" ps -q "$compose_service")"
if [[ -z "$container_id" ]]; then
  log_deploy "找不到 service ${compose_service} 对应的容器"
  rollback
  rm -f "$backup_file"
  exit 1
fi

initial_status="$(docker inspect --format='{{.State.Status}}' "$container_id")"
initial_restarts="$(docker inspect --format='{{.RestartCount}}' "$container_id")"

if [[ "$initial_status" != "running" ]]; then
  log_deploy "up 后容器未运行 (status=${initial_status})"
  rollback
  rm -f "$backup_file"
  exit 1
fi

log_deploy "等待 ${check_seconds} 秒进行稳定性检查"
sleep "$check_seconds"

final_status="$(docker inspect --format='{{.State.Status}}' "$container_id")"
final_restarts="$(docker inspect --format='{{.RestartCount}}' "$container_id")"

if [[ "$final_status" != "running" ]] || (( final_restarts > initial_restarts )); then
  log_deploy "容器不稳定 (status=${final_status}, 重启次数 ${initial_restarts}->${final_restarts})"
  rollback
  rm -f "$backup_file"
  exit 1
fi

versions_set "$SERVICE_NAME" "$image_digest"
remove_image_by_digest "$old_version"
rm -f "$backup_file"

log_deploy "service ${SERVICE_NAME} docker compose 部署完成"

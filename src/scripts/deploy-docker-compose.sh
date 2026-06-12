#!/usr/bin/env bash
# Docker Compose 薄客户端：入队 job 并阻塞等待 daemon 结果

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
# shellcheck source=lib/hooks.sh
source "${DEPLOY_ROOT}/lib/hooks.sh"
# shellcheck source=lib/compose-deploy-ipc.sh
source "${DEPLOY_ROOT}/lib/compose-deploy-ipc.sh"

log_deploy() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

compose_file="$(service_deploy_field "$SERVICE_NAME" compose)"
compose_service="$(service_deploy_field "$SERVICE_NAME" service)"
check_seconds="$(service_deploy_field "$SERVICE_NAME" started-check-seconds)"

run_hook on-deploy-start

job_id="$(compose_job_submit "$SERVICE_NAME" "$compose_file" "$compose_service" "$image_digest" "$check_seconds")"
log_deploy "已入队 compose deploy job ${job_id} (${SERVICE_NAME})"

wait_err=""
if ! wait_err="$(compose_job_wait "$job_id" "$(deploy_timeout_seconds)")"; then
  if [[ ! -f "${COMPOSE_RESPONSES_DIR}/${job_id}" ]]; then
    export hook_deploy_errmsg="$wait_err"
    run_hook on-deploy-fail
  fi
  log_deploy "$wait_err"
  exit 1
fi

touch "${LOG_DIR}/.deploy-executed"
log_deploy "service ${SERVICE_NAME} compose deploy 客户端完成"
exit 0

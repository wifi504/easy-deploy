#!/usr/bin/env bash
# 单个 service：package → deploy

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPLOY_ROOT

if [[ $# -ne 1 ]]; then
  echo "用法: easy-deploy-worker.sh <serviceName>" >&2
  exit 1
fi

SERVICE_NAME="$1"
export SERVICE_NAME

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"
# shellcheck source=lib/logging.sh
source "${DEPLOY_ROOT}/lib/logging.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"

log_msg "worker 已启动，service: ${SERVICE_NAME}"

pkg_type="$(service_package_type "$SERVICE_NAME")"
strategy="$(service_deploy_strategy "$SERVICE_NAME")"

package_script=""
pkg_log=""
case "$pkg_type" in
  generic)
    package_script="${DEPLOY_ROOT}/scripts/package-generic.sh"
    pkg_log="${LOG_DIR}/package-generic.sh.${SERVICE_NAME}.log"
    ;;
  docker-container)
    package_script="${DEPLOY_ROOT}/scripts/package-docker-container.sh"
    pkg_log="${LOG_DIR}/package-docker-container.sh.${SERVICE_NAME}.log"
    ;;
  *) die "未知的 package.type: ${pkg_type}" ;;
esac

mkdir -p "$(dirname "$pkg_log")"

export EASY_DEPLOY_PAYLOAD_MODE=1
if ! pkg_output="$(bash "$package_script" "$SERVICE_NAME" 2>>"$pkg_log")"; then
  unset EASY_DEPLOY_PAYLOAD_MODE
  die "service ${SERVICE_NAME} 的 package 步骤失败"
fi
unset EASY_DEPLOY_PAYLOAD_MODE

mapfile -t pkg_lines <<< "$pkg_output"

if [[ ${#pkg_lines[@]} -eq 0 ]]; then
  die "package 脚本未返回任何输出"
fi

last_line="${pkg_lines[-1]}"

if [[ "$last_line" == "skip_deploy" ]]; then
  log_msg "service ${SERVICE_NAME} 版本未变，跳过部署"
  exit 0
fi

case "$pkg_type" in
  generic)
    if [[ ${#pkg_lines[@]} -lt 2 ]]; then
      die "package-generic.sh 应返回 version 和文件路径"
    fi
    version="${pkg_lines[-2]}"
    artifact_path="${pkg_lines[-1]}"
    deploy_script="${DEPLOY_ROOT}/scripts/deploy-frontend-dist.sh"
    deploy_log="${LOG_DIR}/deploy-frontend-dist.sh.${SERVICE_NAME}.log"
    export EASY_DEPLOY_PAYLOAD_MODE=1
    bash "$deploy_script" "$SERVICE_NAME" "$artifact_path" "$version" 2>>"$deploy_log"
    unset EASY_DEPLOY_PAYLOAD_MODE
    ;;
  docker-container)
    image_digest="$last_line"
    deploy_script="${DEPLOY_ROOT}/scripts/deploy-docker-compose.sh"
    deploy_log="${LOG_DIR}/deploy-docker-compose.sh.${SERVICE_NAME}.log"
    export EASY_DEPLOY_PAYLOAD_MODE=1
    bash "$deploy_script" "$SERVICE_NAME" "$image_digest" 2>>"$deploy_log"
    unset EASY_DEPLOY_PAYLOAD_MODE
    ;;
esac

log_msg "service ${SERVICE_NAME} 的 worker 已成功完成"

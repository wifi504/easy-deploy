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
# shellcheck source=lib/versions.sh
source "${DEPLOY_ROOT}/lib/versions.sh"
# shellcheck source=lib/service-config-hash.sh
source "${DEPLOY_ROOT}/lib/service-config-hash.sh"

_worker_persist_config_hash() {
  local hash="${current_hash:-}"
  if ! versions_file_readable; then
    log_msg "current-versions.json 已存在但无法读取，跳过 config_hash 回存"
    return 0
  fi
  if [[ -z "$hash" ]]; then
    hash="$(service_config_hash "$SERVICE_NAME")"
  fi
  versions_set_config_hash "$SERVICE_NAME" "$hash"
}

trap _worker_persist_config_hash EXIT

log_msg "worker 已启动，service: ${SERVICE_NAME}"

if ! versions_file_readable; then
  log_msg "current-versions.json 已存在但无法读取，跳过 service ${SERVICE_NAME} 本轮处理"
  exit 0
fi

stored_hash="$(versions_get_config_hash "$SERVICE_NAME")"
current_hash="$(service_config_hash "$SERVICE_NAME")"
versions_set_config_hash "$SERVICE_NAME" "$current_hash"
log_msg "service ${SERVICE_NAME} 已记录 config_hash"
force_redeploy=0
if [[ -z "$stored_hash" || "$stored_hash" != "$current_hash" ]]; then
  force_redeploy=1
  if [[ -z "$stored_hash" ]]; then
    log_msg "service ${SERVICE_NAME} 尚无 config_hash，强制 package+deploy"
  else
    log_msg "service ${SERVICE_NAME} 配置已变更，强制 package+deploy"
  fi
fi

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

pkg_args=("$SERVICE_NAME")
if [[ "$force_redeploy" -eq 1 ]]; then
  pkg_args+=("force")
fi

pkg_output=""
pkg_rc=0
pkg_timeout="$(package_timeout_seconds)"

export EASY_DEPLOY_PAYLOAD_MODE=1
set +e
pkg_output="$(timeout "${pkg_timeout}" bash "$package_script" "${pkg_args[@]}" 2>>"$pkg_log")"
pkg_rc=$?
set -e
if [[ "$pkg_rc" -eq 124 ]]; then
  unset EASY_DEPLOY_PAYLOAD_MODE
  die "service ${SERVICE_NAME} 的 package 步骤超时 (${pkg_timeout}s)"
fi
unset EASY_DEPLOY_PAYLOAD_MODE

if [[ "$pkg_rc" -ne 0 ]]; then
  die "service ${SERVICE_NAME} 的 package 步骤失败"
fi

mapfile -t pkg_lines <<< "$pkg_output"

if [[ ${#pkg_lines[@]} -eq 0 ]]; then
  die "package 脚本未返回任何输出"
fi

last_line="${pkg_lines[-1]}"

if [[ "$last_line" == "skip_deploy" ]]; then
  if [[ "$force_redeploy" -eq 1 ]]; then
    die "service ${SERVICE_NAME} 强制 package 仍返回 skip_deploy"
  fi
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
    touch "${LOG_DIR}/.deploy-executed"
    export EASY_DEPLOY_PAYLOAD_MODE=1
    if ! bash "$deploy_script" "$SERVICE_NAME" "$artifact_path" "$version" 2>>"$deploy_log"; then
      unset EASY_DEPLOY_PAYLOAD_MODE
      die "service ${SERVICE_NAME} 的 deploy 步骤失败"
    fi
    unset EASY_DEPLOY_PAYLOAD_MODE
    ;;
  docker-container)
    image_digest="$last_line"
    case "$strategy" in
      docker-compose)
        deploy_script="${DEPLOY_ROOT}/scripts/deploy-docker-compose.sh"
        ;;
      docker-run)
        deploy_script="${DEPLOY_ROOT}/scripts/deploy-docker-run.sh"
        ;;
      *) die "service ${SERVICE_NAME}: 未知的 deploy.strategy: ${strategy}" ;;
    esac
    deploy_log="${LOG_DIR}/$(basename "$deploy_script").${SERVICE_NAME}.log"
    if [[ "$strategy" != "docker-compose" ]]; then
      touch "${LOG_DIR}/.deploy-executed"
    fi
    export EASY_DEPLOY_PAYLOAD_MODE=1
    if ! bash "$deploy_script" "$SERVICE_NAME" "$image_digest" 2>>"$deploy_log"; then
      unset EASY_DEPLOY_PAYLOAD_MODE
      die "service ${SERVICE_NAME} 的 deploy 步骤失败"
    fi
    unset EASY_DEPLOY_PAYLOAD_MODE
    ;;
esac

log_msg "service ${SERVICE_NAME} 的 worker 已成功完成"

#!/usr/bin/env bash
# 通过 tee 初始化各脚本日志（payload 模式下跳过）

if [[ -z "${DEPLOY_ROOT:-}" ]]; then
  DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"

# EASY_DEPLOY_PAYLOAD_MODE=1 时 stdout 保留给机器可读的返回值
if [[ "${EASY_DEPLOY_PAYLOAD_MODE:-0}" == "1" ]]; then
  return 0 2>/dev/null || true
fi

if [[ -z "${LOG_DIR:-}" ]]; then
  LOG_DIR="${DEPLOY_ROOT}/logs/deploy-$(TZ=Asia/Shanghai date +%Y%m%d-%H%M%S)"
fi

mkdir -p "$LOG_DIR"

_script_base="$(basename "${BASH_SOURCE[1]:-${0}}")"
if [[ "$_script_base" == "bash" || "$_script_base" == "source" ]]; then
  _script_base="$(basename "${0}")"
fi

if [[ -n "${SERVICE_NAME:-}" ]]; then
  _log_name="${_script_base}.${SERVICE_NAME}.log"
else
  _log_name="${_script_base}.log"
fi

_log_file="${LOG_DIR}/${_log_name}"

if [[ "${EASY_DEPLOY_LOGGING_INITIALIZED:-0}" != "1" ]]; then
  EASY_DEPLOY_LOGGING_INITIALIZED=1
  export LOG_DIR
  exec > >(tee -a "$_log_file" >/dev/null) 2>&1
  log_msg "日志输出到 ${_log_file}"
fi

unset _script_base _log_name _log_file

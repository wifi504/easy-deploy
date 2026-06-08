#!/usr/bin/env bash
# CD 部署入口：校验 → 加锁 → 后台启动 agent

set -euo pipefail

_script="${BASH_SOURCE[0]}"
while [[ -L "$_script" ]]; do
  _script_dir="$(cd "$(dirname "$_script")" && pwd)"
  _script="$(readlink "$_script")"
  [[ "$_script" != /* ]] && _script="${_script_dir}/${_script}"
done
DEPLOY_ROOT="$(cd "$(dirname "$_script")" && pwd)"
unset _script _script_dir
export DEPLOY_ROOT

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"
# shellcheck source=lib/logging.sh
source "${DEPLOY_ROOT}/lib/logging.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"
# shellcheck source=lib/validate.sh
source "${DEPLOY_ROOT}/lib/validate.sh"
# shellcheck source=lib/lock.sh
source "${DEPLOY_ROOT}/lib/lock.sh"

if [[ $# -ne 0 ]]; then
  die "easy-deploy 不支持传入参数"
fi

# 按 max-log-history 滚动清理旧日志目录
rotate_logs() {
  local max_history
  max_history="$(max_log_history)"
  if [[ -z "$max_history" || "$max_history" == "null" || "$max_history" -lt 0 ]]; then
    return 0
  fi

  mapfile -t log_dirs < <(find "${DEPLOY_ROOT}/logs" -maxdepth 1 -mindepth 1 -type d -name 'deploy-*' | sort -r)
  local count=0 dir
  for dir in "${log_dirs[@]}"; do
    ((count++)) || true
    if [[ "$max_history" -eq 0 ]]; then
      if [[ "$dir" != "$LOG_DIR" ]]; then
        log_msg "删除旧日志目录: ${dir}"
        rm -rf "$dir"
      fi
    elif (( count > max_history )); then
      log_msg "删除旧日志目录: ${dir}"
      rm -rf "$dir"
    fi
  done
}

if ! run_validate; then
  exit 1
fi

rotate_logs

if ! acquire_deploy_lock; then
  log_msg "已有部署任务在运行，无法获取锁"
  exit 0
fi

export LOG_DIR
nohup bash "${DEPLOY_ROOT}/scripts/easy-deploy-agent.sh" "${DEPLOY_LOCK_FD}" &
disown

log_msg "已成功开始执行自动化部署，日志目录：${LOG_DIR}"

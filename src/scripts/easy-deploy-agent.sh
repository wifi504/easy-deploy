#!/usr/bin/env bash
# 并行启动各 service 的 worker，结束后释放锁并清理 temp

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPLOY_ROOT

# 可选：从入口继承已加锁的文件描述符
if [[ $# -ge 1 && "$1" =~ ^[0-9]+$ ]]; then
  DEPLOY_LOCK_FD="$1"
  shift
  _lock_inherited=1
else
  DEPLOY_LOCK_FD=200
  _lock_inherited=0
fi

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"
export LOG_DIR="${LOG_DIR:-}"
# shellcheck source=lib/logging.sh
source "${DEPLOY_ROOT}/lib/logging.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"
# shellcheck source=lib/lock.sh
source "${DEPLOY_ROOT}/lib/lock.sh"
# shellcheck source=lib/versions.sh
source "${DEPLOY_ROOT}/lib/versions.sh"
# shellcheck source=lib/hooks.sh
source "${DEPLOY_ROOT}/lib/hooks.sh"
# shellcheck source=lib/compose-deploy-ipc.sh
source "${DEPLOY_ROOT}/lib/compose-deploy-ipc.sh"

cleanup_agent() {
  release_deploy_lock
}

trap cleanup_agent EXIT

if [[ "$_lock_inherited" -eq 0 ]]; then
  mkdir -p "${DEPLOY_ROOT}/data"
  eval "exec ${DEPLOY_LOCK_FD}>\"${LOCK_FILE}\""
  if ! flock -n "${DEPLOY_LOCK_FD}"; then
    die "agent 无法获取部署锁"
  fi
fi

log_msg "easy-deploy-agent 已启动"
run_hook on-agent-start

versions_ensure
compose_ipc_init

COMPOSE_DAEMON_PID=""
if compose_config_has_services; then
  # 子进程会继承 agent 的 stdout/stderr；重置标志让 daemon 写入独立日志文件
  EASY_DEPLOY_LOGGING_INITIALIZED=0 bash "${DEPLOY_ROOT}/scripts/compose-deploy-daemon.sh" &
  COMPOSE_DAEMON_PID=$!
  log_msg "compose-deploy-daemon 已后台启动 (pid ${COMPOSE_DAEMON_PID})，日志: ${LOG_DIR}/compose-deploy-daemon.sh.log"
fi

declare -a worker_pids=()
declare -a worker_names=()

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  export SERVICE_NAME="$name"
  EASY_DEPLOY_LOGGING_INITIALIZED=0 bash "${DEPLOY_ROOT}/scripts/easy-deploy-worker.sh" "$name" &
  worker_pids+=("$!")
  worker_names+=("$name")
done < <(service_names)

failures=0
for i in "${!worker_pids[@]}"; do
  pid="${worker_pids[$i]}"
  name="${worker_names[$i]}"
  if ! wait "$pid"; then
    log_msg "service ${name} 的 worker 失败 (pid ${pid})"
    failures=$((failures + 1))
  else
    log_msg "service ${name} 的 worker 已完成"
  fi
done

if [[ -n "$COMPOSE_DAEMON_PID" ]]; then
  touch "$COMPOSE_DAEMON_SHUTDOWN_FILE"
  log_msg "已通知 compose-deploy-daemon 退出，等待 pid ${COMPOSE_DAEMON_PID}"
  wait "$COMPOSE_DAEMON_PID" || true
  log_msg "compose-deploy-daemon 已结束"
fi

if [[ -d "$TEMP_DIR" ]]; then
  rm -rf "${TEMP_DIR:?}/"*
  log_msg "已清空临时目录 ${TEMP_DIR}"
fi

if [[ "$failures" -gt 0 ]]; then
  export hook_fail_count="$failures"
  run_hook on-agent-fail
  log_msg "agent 结束，${failures} 个 worker 失败"
else
  run_hook on-agent-success
  log_msg "agent 已成功结束"
fi

# shellcheck source=lib/log-retention.sh
source "${DEPLOY_ROOT}/lib/log-retention.sh"
apply_log_retention "$failures"

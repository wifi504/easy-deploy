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

versions_ensure

declare -a worker_pids=()
declare -a worker_names=()

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  export SERVICE_NAME="$name"
  bash "${DEPLOY_ROOT}/scripts/easy-deploy-worker.sh" "$name" &
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

if [[ -d "$TEMP_DIR" ]]; then
  rm -rf "${TEMP_DIR:?}/"*
  log_msg "已清空临时目录 ${TEMP_DIR}"
fi

if [[ "$failures" -gt 0 ]]; then
  log_msg "agent 结束，${failures} 个 worker 失败"
else
  log_msg "agent 已成功结束"
fi

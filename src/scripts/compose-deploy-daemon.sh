#!/usr/bin/env bash
# Compose Deploy Daemon：按 compose 文件批处理 deploy job（仅队列与 IPC，不触发 hook）

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPLOY_ROOT

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"
# shellcheck source=lib/logging.sh
source "${DEPLOY_ROOT}/lib/logging.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"
# shellcheck source=lib/compose-deploy-ipc.sh
source "${DEPLOY_ROOT}/lib/compose-deploy-ipc.sh"

log_daemon() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $*"
}

compose_build_batch_manifest() {
  local compose_file="$1"
  local job_id service_name compose_service digest check_seconds
  while IFS= read -r job_id; do
    [[ -z "$job_id" ]] && continue
    service_name="$(compose_job_read_field "$job_id" serviceName)"
    compose_service="$(compose_job_read_field "$job_id" composeService)"
    digest="$(compose_job_read_field "$job_id" digest)"
    check_seconds="$(compose_job_read_field "$job_id" checkSeconds)"
    printf '%s\t%s\t%s\t%s\n' "$service_name" "$compose_service" "$digest" "$check_seconds"
  done < <(compose_pending_jobs_for_file "$compose_file")
}

process_compose_file() {
  local compose_file="$1"
  local enc processing_marker timeout_sec start now elapsed stack_rc

  enc="$(compose_path_encode "$compose_file")"
  processing_marker="${COMPOSE_PROCESSING_DIR}/${enc}"

  if [[ -f "$processing_marker" ]]; then
    return 0
  fi

  touch "$processing_marker"

  (
    trap 'rm -f "$processing_marker"' EXIT
    timeout_sec="$(package_timeout_seconds)"
    start="$(date +%s)"

    while ! compose_barrier_satisfied "$compose_file"; do
      if compose_barrier_any_fail "$compose_file"; then
        compose_fail_jobs_for_sibling_package "$compose_file"
        exit 0
      fi
      now="$(date +%s)"
      elapsed=$((now - start))
      if (( elapsed >= timeout_sec )); then
        compose_fail_jobs_for_barrier_timeout "$compose_file" "$timeout_sec"
        exit 0
      fi
      sleep 0.2
    done

    if compose_barrier_any_fail "$compose_file"; then
      compose_fail_jobs_for_sibling_package "$compose_file"
      exit 0
    fi

    local pending_count=0 job_id
    while IFS= read -r job_id; do
      [[ -z "$job_id" ]] && continue
      pending_count=$((pending_count + 1))
    done < <(compose_pending_jobs_for_file "$compose_file")

    if [[ "$pending_count" -eq 0 ]]; then
      exit 0
    fi

    compose_clear_batch_result "$compose_file"
    local manifest_file stack_rc batch_result_file
    manifest_file="${COMPOSE_DEPLOY_DIR}/batch-manifest/${enc}"
    mkdir -p "$(dirname "$manifest_file")"
    compose_build_batch_manifest "$compose_file" >"$manifest_file"

    stack_rc=0
    if ! bash "${DEPLOY_ROOT}/scripts/deploy-docker-compose-stack.sh" "$compose_file" <"$manifest_file"; then
      stack_rc=$?
    fi
    rm -f "$manifest_file"

    batch_result_file="$(compose_batch_result_file "$compose_file")"
    if [[ -f "$batch_result_file" ]] || [[ "$stack_rc" -ne 0 ]]; then
      log_daemon "compose stack 失败 (stack_rc=${stack_rc})，回写 job 失败响应"
      compose_fail_jobs_from_stack "$compose_file"
    else
      compose_succeed_jobs_for_file "$compose_file"
    fi
  ) &
}

daemon_should_exit() {
  [[ -f "$COMPOSE_DAEMON_SHUTDOWN_FILE" ]] || return 1
  local inbox_busy=0
  if [[ -p "$COMPOSE_INBOX_FIFO" ]]; then
    if flock -n -x 200; then
      :
    else
      inbox_busy=1
    fi
  fi 200>"$COMPOSE_INBOX_LOCK"
  [[ "$inbox_busy" -eq 1 ]] && return 1
  [[ "$(compose_processing_count)" -gt 0 ]] && return 1
  local pending_left=0 f
  shopt -s nullglob
  for f in "${COMPOSE_PENDING_DIR}"/*; do
    [[ -f "$f" ]] && pending_left=$((pending_left + 1))
  done
  shopt -u nullglob
  [[ "$pending_left" -eq 0 ]]
}

handle_job_id() {
  local job_id="$1"
  local compose_file job_file="${COMPOSE_PENDING_DIR}/${job_id}"

  if [[ ! -f "$job_file" ]]; then
    log_daemon "忽略未知 job: ${job_id}"
    return 0
  fi

  compose_file="$(compose_job_read_field "$job_id" composeFile)"
  if [[ -z "$compose_file" ]]; then
    log_daemon "job ${job_id} 缺少 composeFile"
    compose_job_write_response "$job_id" "1" "job 配置无效"
    return 0
  fi

  process_compose_file "$compose_file"
}

printf '%s\n' "$$" >"$COMPOSE_DAEMON_PID_FILE"
log_daemon "compose-deploy-daemon 已启动 (pid $$)"

# 保持 fifo 读端常开：若每次 read 都重新 open，在无 writer 时会永久阻塞（-t 管不到 open），
# agent 写入 shutdown 后 daemon 无法退出，部署锁也无法释放。
COMPOSE_INBOX_FD=3
eval "exec ${COMPOSE_INBOX_FD}<>\"${COMPOSE_INBOX_FIFO}\""

while true; do
  if daemon_should_exit; then
    log_daemon "收到 shutdown，daemon 退出"
    break
  fi

  if ! IFS= read -r -t 1 job_id <&"${COMPOSE_INBOX_FD}"; then
    continue
  fi

  job_id="${job_id//$'\r'/}"
  [[ -z "$job_id" ]] && continue
  handle_job_id "$job_id"
done

eval "exec ${COMPOSE_INBOX_FD}>&-"
rm -f "$COMPOSE_DAEMON_PID_FILE"

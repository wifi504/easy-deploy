#!/usr/bin/env bash
# Compose deploy daemon IPC：status、job 队列、屏障辅助

# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"

COMPOSE_DEPLOY_DIR="${TEMP_DIR}/compose-deploy"
COMPOSE_INBOX_FIFO="${COMPOSE_DEPLOY_DIR}/inbox.fifo"
COMPOSE_DAEMON_PID_FILE="${COMPOSE_DEPLOY_DIR}/daemon.pid"
COMPOSE_DAEMON_SHUTDOWN_FILE="${COMPOSE_DEPLOY_DIR}/daemon.shutdown"
COMPOSE_STATUS_DIR="${COMPOSE_DEPLOY_DIR}/status"
COMPOSE_PENDING_DIR="${COMPOSE_DEPLOY_DIR}/pending"
COMPOSE_RESPONSES_DIR="${COMPOSE_DEPLOY_DIR}/responses"
COMPOSE_PROCESSING_DIR="${COMPOSE_DEPLOY_DIR}/processing"
COMPOSE_INBOX_LOCK="${COMPOSE_DEPLOY_DIR}/inbox.lock"

compose_path_encode() {
  local path="$1"
  printf '%s' "$path" | sha256sum | awk '{print $1}'
}

compose_ipc_init() {
  mkdir -p "$COMPOSE_STATUS_DIR" "$COMPOSE_PENDING_DIR" \
    "$COMPOSE_RESPONSES_DIR" "$COMPOSE_PROCESSING_DIR" \
    "${COMPOSE_DEPLOY_DIR}/batch-result" "${COMPOSE_DEPLOY_DIR}/batch-manifest"
  rm -f "$COMPOSE_DAEMON_SHUTDOWN_FILE"
  rm -rf "${COMPOSE_STATUS_DIR:?}/"* "${COMPOSE_PENDING_DIR:?}/"* \
    "${COMPOSE_RESPONSES_DIR:?}/"* "${COMPOSE_PROCESSING_DIR:?}/"* \
    "${COMPOSE_DEPLOY_DIR}/batch-result/"* "${COMPOSE_DEPLOY_DIR}/batch-manifest/"*
  if [[ ! -p "$COMPOSE_INBOX_FIFO" ]]; then
    mkfifo "$COMPOSE_INBOX_FIFO"
  fi
}

compose_config_has_services() {
  local name strategy
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    strategy="$(service_deploy_strategy "$name")"
    if [[ "$strategy" == "docker-compose" ]]; then
      return 0
    fi
  done < <(service_names)
  return 1
}

compose_services_for_file() {
  local compose_file="$1"
  local name strategy compose
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    strategy="$(service_deploy_strategy "$name")"
    if [[ "$strategy" != "docker-compose" ]]; then
      continue
    fi
    compose="$(service_deploy_field "$name" compose)"
    if [[ "$compose" == "$compose_file" ]]; then
      printf '%s\n' "$name"
    fi
  done < <(service_names)
}

compose_status_write() {
  local service="$1" status="$2"
  printf '%s' "$status" >"${COMPOSE_STATUS_DIR}/${service}"
}

compose_status_get() {
  local service="$1"
  local f="${COMPOSE_STATUS_DIR}/${service}"
  if [[ ! -f "$f" ]]; then
    return 1
  fi
  cat "$f"
}

compose_barrier_ready() {
  local compose_file="$1"
  local svc
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    if ! compose_status_get "$svc" >/dev/null 2>&1; then
      return 1
    fi
  done < <(compose_services_for_file "$compose_file")
  return 0
}

compose_barrier_any_fail() {
  local compose_file="$1"
  local svc status
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    status="$(compose_status_get "$svc" 2>/dev/null || true)"
    if [[ "$status" == "fail" ]]; then
      return 0
    fi
  done < <(compose_services_for_file "$compose_file")
  return 1
}

compose_pending_job_for_service() {
  local service_name="$1"
  local job_file job_id
  shopt -s nullglob
  for job_file in "${COMPOSE_PENDING_DIR}"/*; do
    [[ -f "$job_file" ]] || continue
    if grep -qx "serviceName=${service_name}" "$job_file"; then
      basename "$job_file"
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

compose_barrier_satisfied() {
  local compose_file="$1"
  local svc status
  if ! compose_barrier_ready "$compose_file"; then
    return 1
  fi
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    status="$(compose_status_get "$svc")"
    if [[ "$status" == "digest" ]]; then
      if ! compose_pending_job_for_service "$svc" >/dev/null; then
        return 1
      fi
    fi
  done < <(compose_services_for_file "$compose_file")
  return 0
}

compose_pending_jobs_for_file() {
  local compose_file="$1"
  local job_file job_id file_in_job
  shopt -s nullglob
  for job_file in "${COMPOSE_PENDING_DIR}"/*; do
    [[ -f "$job_file" ]] || continue
    file_in_job="$(grep -E '^composeFile=' "$job_file" | head -1 | cut -d= -f2-)"
    if [[ "$file_in_job" == "$compose_file" ]]; then
      basename "$job_file"
    fi
  done
  shopt -u nullglob
}

compose_job_read_field() {
  local job_id="$1" field="$2"
  local job_file="${COMPOSE_PENDING_DIR}/${job_id}"
  grep -E "^${field}=" "$job_file" 2>/dev/null | head -1 | cut -d= -f2-
}

compose_job_submit() {
  local service_name="$1" compose_file="$2" compose_service="$3" digest="$4" check_seconds="$5"
  local job_id="${6:-$(new_uuid)}"

  local job_file="${COMPOSE_PENDING_DIR}/${job_id}"
  {
    printf 'jobId=%s\n' "$job_id"
    printf 'serviceName=%s\n' "$service_name"
    printf 'composeFile=%s\n' "$compose_file"
    printf 'composeService=%s\n' "$compose_service"
    printf 'digest=%s\n' "$digest"
    printf 'checkSeconds=%s\n' "$check_seconds"
  } >"$job_file"

  (
    flock -x 200
    printf '%s\n' "$job_id" >"$COMPOSE_INBOX_FIFO"
  ) 200>"$COMPOSE_INBOX_LOCK"

  printf '%s' "$job_id"
}

compose_job_write_response() {
  local job_id="$1" exit_code="$2" errmsg="$3"
  local resp_file="${COMPOSE_RESPONSES_DIR}/${job_id}"
  {
    printf 'exitCode=%s\n' "$exit_code"
    printf 'errmsg=%s\n' "$errmsg"
  } >"$resp_file"
  rm -f "${COMPOSE_PENDING_DIR}/${job_id}"
}

# 将 compose 文件内的 compose service 名映射为 easy-deploy service 名
compose_easy_name_for_compose_service() {
  local compose_file="$1" compose_svc="$2"
  local name strategy compose deploy_svc
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    strategy="$(service_deploy_strategy "$name")"
    if [[ "$strategy" != "docker-compose" ]]; then
      continue
    fi
    compose="$(service_deploy_field "$name" compose)"
    deploy_svc="$(service_deploy_field "$name" service)"
    if [[ "$compose" == "$compose_file" && "$deploy_svc" == "$compose_svc" ]]; then
      printf '%s' "$name"
      return 0
    fi
  done < <(service_names)
  printf '%s' "$compose_svc"
}

compose_first_failed_service_for_file() {
  local compose_file="$1"
  local svc status
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    status="$(compose_status_get "$svc" 2>/dev/null || true)"
    if [[ "$status" == "fail" ]]; then
      printf '%s' "$svc"
      return 0
    fi
  done < <(compose_services_for_file "$compose_file")
  return 1
}

compose_barrier_blocking_service() {
  local compose_file="$1"
  local svc status
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    if ! compose_status_get "$svc" >/dev/null 2>&1; then
      printf '%s' "$svc"
      return 0
    fi
    status="$(compose_status_get "$svc")"
    if [[ "$status" == "digest" ]] && ! compose_pending_job_for_service "$svc" >/dev/null; then
      printf '%s' "$svc"
      return 0
    fi
  done < <(compose_services_for_file "$compose_file")
  return 1
}

compose_batch_result_file() {
  local compose_file="$1"
  printf '%s/batch-result/%s' "$COMPOSE_DEPLOY_DIR" "$(compose_path_encode "$compose_file")"
}

compose_write_batch_failure() {
  local compose_file="$1" failed_compose_svc="$2" failed_reason="$3"
  local result_file
  result_file="$(compose_batch_result_file "$compose_file")"
  mkdir -p "$(dirname "$result_file")"
  {
    printf 'failedComposeService=%s\n' "$failed_compose_svc"
    printf 'failedReason=%s\n' "$failed_reason"
  } >"$result_file"
}

compose_clear_batch_result() {
  local compose_file="$1"
  rm -f "$(compose_batch_result_file "$compose_file")"
}

compose_succeed_jobs_for_file() {
  local compose_file="$1"
  local job_id
  while IFS= read -r job_id; do
    [[ -z "$job_id" ]] && continue
    compose_job_write_response "$job_id" "0" ""
  done < <(compose_pending_jobs_for_file "$compose_file")
}

compose_fail_jobs_for_sibling_package() {
  local compose_file="$1"
  local cause_svc="${2:-}"
  local job_id errmsg
  if [[ -z "$cause_svc" ]]; then
    cause_svc="$(compose_first_failed_service_for_file "$compose_file")"
  fi
  if [[ -z "$cause_svc" ]]; then
    cause_svc="unknown"
  fi
  while IFS= read -r job_id; do
    [[ -z "$job_id" ]] && continue
    errmsg="同 compose 文件 service ${cause_svc} package 失败"
    compose_job_write_response "$job_id" "1" "$errmsg"
  done < <(compose_pending_jobs_for_file "$compose_file")
}

compose_fail_jobs_for_barrier_timeout() {
  local compose_file="$1" timeout_sec="$2"
  local blocking_svc job_id errmsg
  blocking_svc="$(compose_barrier_blocking_service "$compose_file")"
  while IFS= read -r job_id; do
    [[ -z "$job_id" ]] && continue
    if [[ -n "$blocking_svc" ]]; then
      errmsg="同 compose 文件 service ${blocking_svc} 未在 package 时限内就绪 (等待超时 ${timeout_sec}s)"
    else
      errmsg="等待同 compose 文件 sibling service 超时 (${timeout_sec}s)"
    fi
    compose_job_write_response "$job_id" "1" "$errmsg"
  done < <(compose_pending_jobs_for_file "$compose_file")
}

compose_fail_jobs_from_stack() {
  local compose_file="$1"
  local result_file failed_compose_svc failed_reason cause_easy_name
  local job_id svc_name compose_svc errmsg

  failed_compose_svc=""
  failed_reason="compose stack 部署失败"
  result_file="$(compose_batch_result_file "$compose_file")"
  if [[ -f "$result_file" ]]; then
    failed_compose_svc="$(grep -E '^failedComposeService=' "$result_file" | head -1 | cut -d= -f2-)"
    failed_reason="$(grep -E '^failedReason=' "$result_file" | head -1 | cut -d= -f2-)"
    rm -f "$result_file"
  fi

  cause_easy_name=""
  if [[ -n "$failed_compose_svc" ]]; then
    cause_easy_name="$(compose_easy_name_for_compose_service "$compose_file" "$failed_compose_svc")"
  fi

  while IFS= read -r job_id; do
    [[ -z "$job_id" ]] && continue
    compose_svc="$(compose_job_read_field "$job_id" composeService)"
    if [[ -n "$failed_compose_svc" && "$compose_svc" == "$failed_compose_svc" ]]; then
      errmsg="$failed_reason"
    elif [[ -n "$failed_compose_svc" ]]; then
      errmsg="同 compose 文件 service ${cause_easy_name} 部署失败: ${failed_reason}"
    else
      errmsg="$failed_reason"
    fi
    compose_job_write_response "$job_id" "1" "$errmsg"
  done < <(compose_pending_jobs_for_file "$compose_file")
}

compose_job_response_field() {
  local job_id="$1" field="$2"
  local resp_file="${COMPOSE_RESPONSES_DIR}/${job_id}"
  [[ -f "$resp_file" ]] || return 1
  grep -E "^${field}=" "$resp_file" | head -1 | cut -d= -f2-
}

compose_job_wait() {
  local job_id="$1"
  local timeout_sec="${2:-$(deploy_timeout_seconds)}"
  local resp_file="${COMPOSE_RESPONSES_DIR}/${job_id}"
  local start now elapsed exit_code errmsg line

  start="$(date +%s)"
  while [[ ! -f "$resp_file" ]]; do
    if [[ ! -f "${COMPOSE_DAEMON_PID_FILE}" ]] && [[ ! -f "${COMPOSE_PENDING_DIR}/${job_id}" ]]; then
      printf '%s' "compose deploy daemon 未运行或 job 已丢失"
      return 1
    fi
    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed >= timeout_sec )); then
      printf '%s' "等待 compose deploy 响应超时 (${timeout_sec}s)"
      return 1
    fi
    sleep 0.2
  done

  exit_code=""
  errmsg=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      exitCode=*) exit_code="${line#exitCode=}" ;;
      errmsg=*) errmsg="${line#errmsg=}" ;;
    esac
  done <"$resp_file"

  if [[ -z "$exit_code" ]]; then
    printf '%s' "compose deploy 响应格式无效"
    return 1
  fi

  if [[ "$exit_code" != "0" ]]; then
    printf '%s' "${errmsg:-compose deploy 失败}"
    return 1
  fi
  return 0
}

compose_processing_active() {
  local compose_file="$1"
  local enc
  enc="$(compose_path_encode "$compose_file")"
  [[ -f "${COMPOSE_PROCESSING_DIR}/${enc}" ]]
}

compose_processing_count() {
  local n=0 f
  shopt -s nullglob
  for f in "${COMPOSE_PROCESSING_DIR}"/*; do
    [[ -f "$f" ]] && n=$((n + 1))
  done
  shopt -u nullglob
  printf '%s' "$n"
}

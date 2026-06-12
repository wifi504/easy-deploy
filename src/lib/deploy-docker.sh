#!/usr/bin/env bash
# Docker 部署共用：argv 读取、容器名解析、稳定性检查、镜像清理

# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"

is_valid_started_check_seconds() {
  [[ "$1" =~ ^-1$ || "$1" =~ ^[1-9][0-9]*$ ]]
}

_read_yq_argv_field() {
  local yq_path="$1"
  local -n _out="$2"
  _out=()

  local tag
  tag="$("$YQ_BIN" eval "${yq_path} | tag" "$CONFIG_FILE")"

  if [[ "$tag" == "!!null" || -z "$tag" ]]; then
    return 0
  fi

  if [[ "$tag" == "!!seq" ]]; then
    local line
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != "null" ]] && _out+=("$line")
    done < <("$YQ_BIN" eval -r "${yq_path} | .[]" "$CONFIG_FILE")
  else
    local raw
    raw="$("$YQ_BIN" eval -r "$yq_path" "$CONFIG_FILE")"
    if [[ -n "$raw" && "$raw" != "null" ]]; then
      read -ra _tmp <<< "$raw"
      _out=("${_tmp[@]}")
    fi
  fi
}

read_deploy_argv_field() {
  local service="$1" field="$2"
  local -n _out="$3"
  _read_yq_argv_field ".services[] | select(.name == \"${service}\") | .deploy.${field}" _out
}

docker_run_container_count() {
  local service="$1"
  local count tag
  tag="$("$YQ_BIN" eval ".services[] | select(.name == \"${service}\") | .deploy.containers | tag" "$CONFIG_FILE")"
  if [[ "$tag" != "!!seq" ]]; then
    printf '0'
    return 0
  fi
  count="$("$YQ_BIN" eval ".services[] | select(.name == \"${service}\") | .deploy.containers | length" "$CONFIG_FILE")"
  printf '%s' "$count"
}

read_container_argv_field() {
  local service="$1" index="$2" field="$3"
  local -n _out="$4"
  _read_yq_argv_field ".services[] | select(.name == \"${service}\") | .deploy.containers[${index}].${field}" _out
}

parse_container_name_from_argv() {
  local -a argv=("$@")
  local i name=""
  for ((i = 0; i < ${#argv[@]}; i++)); do
    local arg="${argv[i]}"
    if [[ "$arg" == --name=* ]]; then
      name="${arg#--name=}"
      break
    elif [[ "$arg" == --name ]]; then
      if (( i + 1 < ${#argv[@]} )); then
        name="${argv[i + 1]}"
      fi
      break
    fi
  done
  printf '%s' "$name"
}

dedupe_d_flag() {
  local -n _opts="$1"
  local -a filtered=()
  local arg
  for arg in "${_opts[@]}"; do
    [[ "$arg" == "-d" || "$arg" == "--detach" ]] && continue
    filtered+=("$arg")
  done
  _opts=("${filtered[@]}")
}

remove_image_by_digest() {
  local host="$1" owner="$2" pkg_name="$3" digest="$4"
  [[ -z "$digest" ]] && return 0
  docker rmi -f "${host}/${owner}/${pkg_name}@${digest}" >/dev/null 2>&1 || true
}

# 成功返回 0；失败时向 stdout 输出错误信息并返回 1
container_stability_check() {
  local container_id="$1"
  local check_seconds="$2"

  if [[ "$check_seconds" == "-1" ]]; then
    return 0
  fi

  local initial_status initial_restarts final_status final_restarts
  initial_status="$(docker inspect --format='{{.State.Status}}' "$container_id")"
  initial_restarts="$(docker inspect --format='{{.RestartCount}}' "$container_id")"

  if [[ "$initial_status" != "running" ]]; then
    printf '%s' "up 后容器未运行 (status=${initial_status})"
    return 1
  fi

  sleep "$check_seconds"

  final_status="$(docker inspect --format='{{.State.Status}}' "$container_id")"
  final_restarts="$(docker inspect --format='{{.RestartCount}}' "$container_id")"

  if [[ "$final_status" != "running" ]] || (( final_restarts > initial_restarts )); then
    printf '%s' "容器不稳定 (status=${final_status}, 重启次数 ${initial_restarts}->${final_restarts})"
    return 1
  fi
  return 0
}

# 输出两行：status 与 restartCount（供 batch 阶梯检查）
container_stability_snapshot() {
  local container_id="$1"
  docker inspect --format='{{.State.Status}}' "$container_id"
  docker inspect --format='{{.RestartCount}}' "$container_id"
}

# 对比 snapshot；失败时向 stdout 输出错误信息
container_stability_verify() {
  local container_id="$1"
  local initial_status="$2"
  local initial_restarts="$3"

  local final_status final_restarts
  final_status="$(docker inspect --format='{{.State.Status}}' "$container_id")"
  final_restarts="$(docker inspect --format='{{.RestartCount}}' "$container_id")"

  if [[ "$final_status" != "running" ]]; then
    printf '%s' "up 后容器未运行 (status=${final_status})"
    return 1
  fi
  if (( final_restarts > initial_restarts )); then
    printf '%s' "容器不稳定 (status=${final_status}, 重启次数 ${initial_restarts}->${final_restarts})"
    return 1
  fi
  return 0
}

# stdin：每行 composeService<TAB>containerId<TAB>checkSeconds
# 升序阶梯检查；-1 跳过
compose_batch_stability_check() {
  local -a svc_names=() svc_ids=() svc_checks=()
  local line compose_svc container_id check_seconds
  local -a checkpoints=()
  local cp i err elapsed start now target sleep_sec

  while IFS=$'\t' read -r compose_svc container_id check_seconds; do
    [[ -z "$compose_svc" ]] && continue
    svc_names+=("$compose_svc")
    svc_ids+=("$container_id")
    svc_checks+=("$check_seconds")
    if [[ "$check_seconds" != "-1" && "$check_seconds" =~ ^[1-9][0-9]*$ ]]; then
      local found=0
      for cp in "${checkpoints[@]}"; do
        if [[ "$cp" == "$check_seconds" ]]; then
          found=1
          break
        fi
      done
      if [[ "$found" -eq 0 ]]; then
        checkpoints+=("$check_seconds")
      fi
    fi
  done

  if [[ ${#checkpoints[@]} -eq 0 ]]; then
    return 0
  fi

  IFS=$'\n' checkpoints=($(printf '%s\n' "${checkpoints[@]}" | sort -n))
  unset IFS

  local -a snap_status=() snap_restarts=()
  for ((i = 0; i < ${#svc_ids[@]}; i++)); do
    if [[ "${svc_checks[$i]}" == "-1" ]]; then
      snap_status+=("")
      snap_restarts+=("")
      continue
    fi
    mapfile -t _snap < <(container_stability_snapshot "${svc_ids[$i]}")
    snap_status+=("${_snap[0]}")
    snap_restarts+=("${_snap[1]}")
    if [[ "${snap_status[$i]}" != "running" ]]; then
      printf '%s' "up 后容器未运行 (service=${svc_names[$i]}, status=${snap_status[$i]})"
      return 1
    fi
  done

  start="$(date +%s)"
  elapsed=0
  for cp in "${checkpoints[@]}"; do
    target="$cp"
    sleep_sec=$((target - elapsed))
    if (( sleep_sec > 0 )); then
      sleep "$sleep_sec"
    fi
    now="$(date +%s)"
    elapsed=$((now - start))

    for ((i = 0; i < ${#svc_ids[@]}; i++)); do
      check_seconds="${svc_checks[$i]}"
      [[ "$check_seconds" == "-1" ]] && continue
      if [[ "$check_seconds" != "$cp" ]]; then
        continue
      fi
      err=""
      if ! err="$(container_stability_verify "${svc_ids[$i]}" "${snap_status[$i]}" "${snap_restarts[$i]}")"; then
        printf '%s' "${svc_names[$i]}: ${err}"
        return 1
      fi
    done
  done
  return 0
}

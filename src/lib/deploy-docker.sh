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

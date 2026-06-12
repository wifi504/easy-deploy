#!/usr/bin/env bash
# Step1 配置校验

# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"
# shellcheck source=lib/deploy-docker.sh
source "${DEPLOY_ROOT}/lib/deploy-docker.sh"

VALIDATE_ERRORS=()

validate_fail() {
  VALIDATE_ERRORS+=("$1")
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    validate_fail "缺少必需命令: ${cmd}"
  fi
}

is_valid_service_name() {
  [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]
}

has_duplicate() {
  local -a items=("$@")
  local i j
  for ((i = 0; i < ${#items[@]}; i++)); do
    for ((j = i + 1; j < ${#items[@]}; j++)); do
      if [[ "${items[i]}" == "${items[j]}" ]]; then
        return 0
      fi
    done
  done
  return 1
}

validate_gitea() {
  local token url
  token="$(gitea_token 2>/dev/null)" || {
    validate_fail "无法解析 gitea.token"
    return
  }
  url="$(gitea_url)"
  if [[ -z "$url" ]]; then
    validate_fail "gitea.url 为空"
    return
  fi
  if [[ -z "$token" ]]; then
    validate_fail "gitea.token 为空"
    return
  fi
  if ! curl -sf -H "Authorization: token ${token}" "${url}/api/v1/user" >/dev/null; then
    validate_fail "无法连接 Gitea 或 token 无效 (${url})"
  fi
}

validate_dependencies() {
  require_command curl
  require_command jq
  if ! resolve_yq_bin; then
    validate_fail "缺少 mikefarah/yq（Go 版）。请运行 install.sh 安装，勿使用 apt 的 Python 版 yq"
  elif command -v yq >/dev/null 2>&1 && [[ "$(command -v yq)" != "$YQ_BIN" ]] && ! is_mikefarah_yq "$(command -v yq)"; then
    validate_fail "检测到 Python 版 yq（kislyuk），与 easy-deploy 不兼容。请使用 ${YQ_BIN}（mikefarah/yq）"
  fi
  require_command docker
  require_command unzip
  require_command tar
  require_command 7z
  if ! docker compose version >/dev/null 2>&1; then
    validate_fail "docker compose (V2) 不可用"
  fi
}

validate_directories() {
  mkdir -p "${DEPLOY_ROOT}/data" "${DEPLOY_ROOT}/logs" "${DEPLOY_ROOT}/data/temp" || \
    validate_fail "无法创建 data/ 或 logs/ 目录"
}

validate_services() {
  local count
  count="$(service_count)"
  if [[ "$count" -eq 0 || "$count" == "null" ]]; then
    validate_fail "services 不能为空"
    return
  fi

  local -a names=()
  local -a frontend_targets=()
  local -a compose_paths=()
  local -a docker_run_container_names=()
  declare -A package_key_first_service=()
  local has_frontend=0
  local i name

  for ((i = 0; i < count; i++)); do
    name="$(service_name_at "$i")"
    if [[ -z "$name" || "$name" == "null" ]]; then
      validate_fail "services[$i].name 缺失"
      continue
    fi
    if ! is_valid_service_name "$name"; then
      validate_fail "service 名称无效（须匹配 ^[a-zA-Z0-9._-]+$）: ${name}"
    fi
    names+=("$name")

    local pkg_type strategy owner pkg_name pkg_file target compose svc started reload
    pkg_type="$(service_package_type "$name")"
    strategy="$(service_deploy_strategy "$name")"
    owner="$(service_package_field "$name" owner)"
    pkg_name="$(service_package_field "$name" name)"

    if [[ -z "$pkg_type" || "$pkg_type" == "null" ]]; then
      validate_fail "service ${name}: package.type 缺失"
    elif [[ "$pkg_type" != "generic" && "$pkg_type" != "docker-container" ]]; then
      validate_fail "service ${name}: 不支持的 package.type '${pkg_type}'"
    fi

    if [[ -z "$strategy" || "$strategy" == "null" ]]; then
      validate_fail "service ${name}: deploy.strategy 缺失"
    elif [[ "$strategy" != "frontend-dist" && "$strategy" != "docker-compose" && "$strategy" != "docker-run" ]]; then
      validate_fail "service ${name}: 不支持的 deploy.strategy '${strategy}'"
    fi

    if [[ "$pkg_type" == "generic" && "$strategy" != "frontend-dist" ]]; then
      validate_fail "service ${name}: generic 必须与 frontend-dist 配对"
    fi
    if [[ "$pkg_type" == "docker-container" && "$strategy" != "docker-compose" && "$strategy" != "docker-run" ]]; then
      validate_fail "service ${name}: docker-container 必须与 docker-compose 或 docker-run 配对"
    fi

    if [[ -z "$owner" || "$owner" == "null" ]]; then
      validate_fail "service ${name}: package.owner 缺失"
    fi
    if [[ -z "$pkg_name" || "$pkg_name" == "null" ]]; then
      validate_fail "service ${name}: package.name 缺失"
    fi

    if [[ "$pkg_type" == "docker-container" ]]; then
      local pkg_key="${owner}/${pkg_name}"
      if [[ -n "${package_key_first_service[$pkg_key]:-}" ]]; then
        validate_fail "package owner/name 重复: ${pkg_key} (service: ${package_key_first_service[$pkg_key]}, ${name})"
      else
        package_key_first_service[$pkg_key]="$name"
      fi
    fi

    if [[ "$pkg_type" == "generic" ]]; then
      pkg_file="$(service_package_field "$name" file)"
      if [[ -z "$pkg_file" || "$pkg_file" == "null" ]]; then
        validate_fail "service ${name}: generic 类型必须配置 package.file"
      else
        local pkg_key="${owner}/${pkg_name}/${pkg_file}"
        if [[ -n "${package_key_first_service[$pkg_key]:-}" ]]; then
          validate_fail "package owner/name/file 重复: ${pkg_key} (service: ${package_key_first_service[$pkg_key]}, ${name})"
        else
          package_key_first_service[$pkg_key]="$name"
        fi
      fi
      target="$(service_deploy_field "$name" target)"
      if [[ -z "$target" || "$target" == "null" ]]; then
        validate_fail "service ${name}: deploy.target 缺失"
      elif [[ ! -d "$target" ]]; then
        validate_fail "service ${name}: deploy.target 不是目录: ${target}"
      elif [[ ! -w "$target" ]]; then
        validate_fail "service ${name}: deploy.target 不可写: ${target}"
      else
        frontend_targets+=("$target")
        has_frontend=1
      fi
    fi

    if [[ "$strategy" == "docker-compose" ]]; then
      compose="$(service_deploy_field "$name" compose)"
      svc="$(service_deploy_field "$name" service)"
      started="$(service_deploy_field "$name" started-check-seconds)"
      if [[ -z "$compose" || "$compose" == "null" ]]; then
        validate_fail "service ${name}: deploy.compose 缺失"
      elif [[ ! -f "$compose" ]]; then
        validate_fail "service ${name}: compose 文件不存在: ${compose}"
      else
        compose_paths+=("$compose")
        if [[ -z "$svc" || "$svc" == "null" ]]; then
          validate_fail "service ${name}: deploy.service 缺失"
        elif [[ "$("$YQ_BIN" eval ".services | has(\"${svc}\")" "$compose")" != "true" ]]; then
          validate_fail "service ${name}: compose 中找不到 deploy.service '${svc}' (${compose})"
        fi
      fi
      if [[ -z "$started" || "$started" == "null" ]] || ! is_valid_started_check_seconds "$started"; then
        validate_fail "service ${name}: deploy.started-check-seconds 必须是正整数或 -1（禁用稳定性检查）"
      fi
    fi

    if [[ "$strategy" == "docker-run" ]]; then
      local container_tag container_count c
      local -a run_opts=()
      local container_name
      container_tag="$("$YQ_BIN" eval ".services[] | select(.name == \"${name}\") | .deploy.containers | tag" "$CONFIG_FILE")"
      if [[ "$container_tag" != "!!seq" ]]; then
        validate_fail "service ${name}: deploy.containers 必须是至少包含 1 项的数组"
      else
        container_count="$(docker_run_container_count "$name")"
        if [[ "$container_count" -lt 1 ]]; then
          validate_fail "service ${name}: deploy.containers 不能为空"
        fi
        for ((c = 0; c < container_count; c++)); do
          run_opts=()
          read_container_argv_field "$name" "$c" options run_opts
          if [[ ${#run_opts[@]} -eq 0 ]]; then
            validate_fail "service ${name}: deploy.containers[${c}].options 缺失"
          else
            container_name="$(parse_container_name_from_argv "${run_opts[@]}")"
            if [[ -z "$container_name" ]]; then
              validate_fail "service ${name}: deploy.containers[${c}].options 必须包含 --name"
            else
              docker_run_container_names+=("$container_name")
            fi
          fi
        done
      fi
      started="$(service_deploy_field "$name" started-check-seconds)"
      if [[ -z "$started" || "$started" == "null" ]] || ! is_valid_started_check_seconds "$started"; then
        validate_fail "service ${name}: deploy.started-check-seconds 必须是正整数或 -1（禁用稳定性检查）"
      fi
    fi
  done

  if has_duplicate "${names[@]}"; then
    validate_fail "存在重复的 service 名称"
  fi
  if [[ ${#frontend_targets[@]} -gt 0 ]] && has_duplicate "${frontend_targets[@]}"; then
    validate_fail "frontend-dist 服务的 deploy.target 存在重复"
  fi
  if [[ ${#compose_paths[@]} -gt 0 ]] && has_duplicate "${compose_paths[@]}"; then
    validate_fail "docker-compose 服务的 deploy.compose 存在重复"
  fi
  if [[ ${#docker_run_container_names[@]} -gt 0 ]] && has_duplicate "${docker_run_container_names[@]}"; then
    validate_fail "docker-run 服务的容器名 (--name) 存在重复"
  fi

  if [[ "$has_frontend" -eq 1 ]]; then
    reload="$(reload_nginx_cmd)"
    if [[ -z "$reload" || "$reload" == "null" ]]; then
      validate_fail "存在 frontend-dist 服务时，scripts.reload-nginx-cmd 不能为空"
    fi
  fi
}

validate_logs() {
  local level
  level="$(cfg_raw '.logs.level')"
  if [[ -z "$level" || "$level" == "null" ]]; then
    return 0
  fi
  case "$level" in
    always|deploy|error) ;;
    *) validate_fail "logs.level 无效: ${level}（允许值: always | deploy | error）" ;;
  esac
}

run_validate() {
  VALIDATE_ERRORS=()
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "配置文件不存在: ${CONFIG_FILE}" >&2
    return 1
  fi
  validate_directories
  validate_logs
  validate_dependencies
  validate_gitea
  validate_services

  if [[ ${#VALIDATE_ERRORS[@]} -gt 0 ]]; then
    log_msg "配置校验失败:"
    local err
    for err in "${VALIDATE_ERRORS[@]}"; do
      echo "  - ${err}"
    done
    return 1
  fi
  log_msg "配置校验通过"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${DEPLOY_ROOT}/lib/common.sh"
  source "${DEPLOY_ROOT}/lib/config.sh"
  run_validate
fi

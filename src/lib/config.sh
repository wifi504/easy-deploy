#!/usr/bin/env bash
# 读取 easy-deploy-config.yaml 与 Gitea 相关配置

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"

cfg() {
  yq eval "$1" "$CONFIG_FILE"
}

cfg_raw() {
  yq eval -r "$1" "$CONFIG_FILE"
}

resolve_token() {
  local raw="${1:-}"
  if [[ "$raw" =~ ^\$\{([^}]+)\}$ ]]; then
    local var_name="${BASH_REMATCH[1]}"
    local value="${!var_name:-}"
    if [[ -z "$value" ]]; then
      die "环境变量 ${var_name} 未设置（gitea.token 需要）"
    fi
    printf '%s' "$value"
  else
    printf '%s' "$raw"
  fi
}

gitea_token() {
  resolve_token "$(cfg_raw '.gitea.token')"
}

gitea_url() {
  cfg_raw '.gitea.url'
}

gitea_host() {
  local url
  url="$(gitea_url)"
  url="${url#http://}"
  url="${url#https://}"
  printf '%s' "$url"
}

service_count() {
  cfg '.services | length'
}

service_name_at() {
  cfg_raw ".services[$1].name"
}

service_names() {
  local count i
  count="$(service_count)"
  for ((i = 0; i < count; i++)); do
    service_name_at "$i"
  done
}

service_package_type() {
  cfg_raw ".services[] | select(.name == \"$1\") | .package.type"
}

service_deploy_strategy() {
  cfg_raw ".services[] | select(.name == \"$1\") | .deploy.strategy"
}

service_package_field() {
  local name="$1" field="$2"
  cfg_raw ".services[] | select(.name == \"$1\") | .package.${field}"
}

service_deploy_field() {
  local name="$1" field="$2"
  cfg_raw ".services[] | select(.name == \"$1\") | .deploy.${field}"
}

reload_nginx_cmd() {
  cfg_raw '.scripts."reload-nginx-cmd"'
}

max_log_history() {
  cfg_raw '.logs."max-log-history"'
}

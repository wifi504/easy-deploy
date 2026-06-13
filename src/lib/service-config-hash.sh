#!/usr/bin/env bash
# service 的 package+deploy 配置段 hash（gzip + sha256）

# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"

service_config_hash() {
  local service="$1"
  local yaml hex

  if ! yaml="$("$YQ_BIN" eval -o=yaml -I 2 \
    ".services[] | select(.name == \"${service}\") | del(.name)" "$CONFIG_FILE" 2>/dev/null)"; then
    die "config_hash: yq 无法提取 service ${service} 的 package/deploy 配置"
  fi

  if [[ -z "$yaml" || "$yaml" == "null" ]]; then
    die "config_hash: 配置中未找到 service ${service}"
  fi

  hex="$(printf '%s' "$yaml" | gzip -cn | sha256sum | awk '{print $1}')"
  printf 'sha256:%s' "$hex"
}

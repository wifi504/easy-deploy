#!/usr/bin/env bash
# service 的 package+deploy 配置段 hash（gzip + sha256）

# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"

service_config_hash() {
  local service="$1"
  local hex

  hex="$("$YQ_BIN" eval -o=yaml -I 2 \
    ".services[] | select(.name == \"${service}\") | {package, deploy}" "$CONFIG_FILE" \
    | gzip -cn | sha256sum | awk '{print $1}')"
  printf 'sha256:%s' "$hex"
}

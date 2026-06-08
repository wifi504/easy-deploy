#!/usr/bin/env bash
# 所有 easy-deploy 脚本的公共引导

set -euo pipefail

if [[ -z "${DEPLOY_ROOT:-}" ]]; then
  DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

cd "$DEPLOY_ROOT"

CONFIG_FILE="${DEPLOY_ROOT}/easy-deploy-config.yaml"
VERSIONS_FILE="${DEPLOY_ROOT}/data/current-versions.json"
LOCK_FILE="${DEPLOY_ROOT}/data/easy-deploy.lock"
TEMP_DIR="${DEPLOY_ROOT}/data/temp"

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    date +%s%N-$RANDOM
  fi
}

log_msg() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  log_msg "错误: $*"
  exit 1
}

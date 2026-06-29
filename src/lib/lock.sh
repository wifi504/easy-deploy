#!/usr/bin/env bash
# 部署锁：flock 非阻塞加锁 / 释放

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"

DEPLOY_LOCK_FD=200

acquire_deploy_lock() {
  mkdir -p "${DEPLOY_ROOT}/data"
  eval "exec ${DEPLOY_LOCK_FD}>\"${LOCK_FILE}\""
  if ! flock -n "${DEPLOY_LOCK_FD}"; then
    return 1
  fi
  return 0
}

release_deploy_lock() {
  flock -u "${DEPLOY_LOCK_FD}" 2>/dev/null || true
}

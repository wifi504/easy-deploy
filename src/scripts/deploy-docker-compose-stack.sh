#!/usr/bin/env bash
# Compose batch deploy：由 compose-deploy-daemon 调用

set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPLOY_ROOT

if [[ $# -ne 1 ]]; then
  echo "用法: deploy-docker-compose-stack.sh <composeFile>" >&2
  exit 1
fi

COMPOSE_FILE="$1"

# shellcheck source=lib/common.sh
source "${DEPLOY_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_ROOT}/lib/config.sh"
# shellcheck source=lib/compose-deploy-ipc.sh
source "${DEPLOY_ROOT}/lib/compose-deploy-ipc.sh"
# shellcheck source=lib/versions.sh
source "${DEPLOY_ROOT}/lib/versions.sh"
# shellcheck source=lib/deploy-docker.sh
source "${DEPLOY_ROOT}/lib/deploy-docker.sh"

log_stack() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

declare -a BATCH_SERVICE_NAMES=()
declare -a BATCH_COMPOSE_SERVICES=()
declare -a BATCH_DIGESTS=()
declare -a BATCH_CHECK_SECONDS=()

while IFS=$'\t' read -r svc_name compose_svc digest check_seconds; do
  [[ -z "$svc_name" ]] && continue
  BATCH_SERVICE_NAMES+=("$svc_name")
  BATCH_COMPOSE_SERVICES+=("$compose_svc")
  BATCH_DIGESTS+=("$digest")
  BATCH_CHECK_SECONDS+=("$check_seconds")
done

if [[ ${#BATCH_SERVICE_NAMES[@]} -eq 0 ]]; then
  log_stack "batch 为空，跳过"
  exit 0
fi

host="$(gitea_host)"
compose_lock="${COMPOSE_FILE}.easy-deploy.lock"
backup_file="${COMPOSE_FILE}.easy-deploy.bak"
COMPOSE_LOCK_FD=210

eval "exec ${COMPOSE_LOCK_FD}>\"${compose_lock}\""
flock "${COMPOSE_LOCK_FD}"

cp "$COMPOSE_FILE" "$backup_file"

declare -a OLD_VERSIONS=()
declare -a IMAGE_REFS=()
for ((i = 0; i < ${#BATCH_SERVICE_NAMES[@]}; i++)); do
  svc_name="${BATCH_SERVICE_NAMES[$i]}"
  digest="${BATCH_DIGESTS[$i]}"
  owner="$(service_package_field "$svc_name" owner)"
  pkg_name="$(service_package_field "$svc_name" name)"
  OLD_VERSIONS+=("$(versions_get "$svc_name")")
  IMAGE_REFS+=("${host}/${owner}/${pkg_name}@${digest}")
done

for ((i = 0; i < ${#BATCH_COMPOSE_SERVICES[@]}; i++)); do
  compose_svc="${BATCH_COMPOSE_SERVICES[$i]}"
  image_ref="${IMAGE_REFS[$i]}"
  log_stack "更新 compose 服务 ${compose_svc} 的 image 为 ${image_ref}"
  "$YQ_BIN" eval -i ".services[\"${compose_svc}\"].image = \"${image_ref}\"" "$COMPOSE_FILE"
done

up_services=("${BATCH_COMPOSE_SERVICES[@]}")
log_stack "执行: docker compose up -d --no-deps --force-recreate ${up_services[*]}"
if ! docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "${up_services[@]}"; then
  log_stack "docker compose up 失败，开始回滚"
  compose_write_batch_failure "$COMPOSE_FILE" "" "docker compose up 失败"
  cp "$backup_file" "$COMPOSE_FILE"
  docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "${up_services[@]}" || true
  for ((i = 0; i < ${#BATCH_SERVICE_NAMES[@]}; i++)); do
    svc_name="${BATCH_SERVICE_NAMES[$i]}"
    owner="$(service_package_field "$svc_name" owner)"
    pkg_name="$(service_package_field "$svc_name" name)"
    remove_image_by_digest "$host" "$owner" "$pkg_name" "${BATCH_DIGESTS[$i]}"
  done
  rm -f "$backup_file"
  exit 1
fi

stability_input=""
for ((i = 0; i < ${#BATCH_COMPOSE_SERVICES[@]}; i++)); do
  compose_svc="${BATCH_COMPOSE_SERVICES[$i]}"
  check_seconds="${BATCH_CHECK_SECONDS[$i]}"
  container_id="$(docker compose -f "$COMPOSE_FILE" ps -q "$compose_svc")"
  if [[ -z "$container_id" ]]; then
    log_stack "找不到 service ${compose_svc} 对应的容器，开始回滚"
    compose_write_batch_failure "$COMPOSE_FILE" "$compose_svc" "找不到 service ${compose_svc} 对应的容器"
    cp "$backup_file" "$COMPOSE_FILE"
    docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "${up_services[@]}" || true
    for ((j = 0; j < ${#BATCH_SERVICE_NAMES[@]}; j++)); do
      svc_name="${BATCH_SERVICE_NAMES[$j]}"
      owner="$(service_package_field "$svc_name" owner)"
      pkg_name="$(service_package_field "$svc_name" name)"
      remove_image_by_digest "$host" "$owner" "$pkg_name" "${BATCH_DIGESTS[$j]}"
    done
    rm -f "$backup_file"
    exit 1
  fi
  stability_input+="${compose_svc}"$'\t'"${container_id}"$'\t'"${check_seconds}"$'\n'
done

stability_err=""
if ! stability_err="$(printf '%s' "$stability_input" | compose_batch_stability_check)"; then
  log_stack "稳定性检查失败: ${stability_err}，开始回滚"
  compose_write_batch_failure "$COMPOSE_FILE" "${stability_err%%:*}" "${stability_err#*: }"
  cp "$backup_file" "$COMPOSE_FILE"
  docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "${up_services[@]}" || true
  for ((j = 0; j < ${#BATCH_SERVICE_NAMES[@]}; j++)); do
    svc_name="${BATCH_SERVICE_NAMES[$j]}"
    owner="$(service_package_field "$svc_name" owner)"
    pkg_name="$(service_package_field "$svc_name" name)"
    remove_image_by_digest "$host" "$owner" "$pkg_name" "${BATCH_DIGESTS[$j]}"
  done
  rm -f "$backup_file"
  exit 1
fi

for ((i = 0; i < ${#BATCH_SERVICE_NAMES[@]}; i++)); do
  svc_name="${BATCH_SERVICE_NAMES[$i]}"
  digest="${BATCH_DIGESTS[$i]}"
  owner="$(service_package_field "$svc_name" owner)"
  pkg_name="$(service_package_field "$svc_name" name)"
  versions_set "$svc_name" "$digest"
  remove_image_by_digest "$host" "$owner" "$pkg_name" "${OLD_VERSIONS[$i]}"
done

rm -f "$backup_file"
compose_clear_batch_result "$COMPOSE_FILE"
log_stack "compose stack 部署成功 (${#BATCH_SERVICE_NAMES[@]} 个 service)"
exit 0

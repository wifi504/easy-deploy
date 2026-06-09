#!/usr/bin/env bash
# 部署事件钩子：读取配置、阻塞执行用户命令、记录日志（失败不中断主流程）

hook_log() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] [hook] $*" >&2
}

# 将命令字符串中的 ${hook_*} 替换为已 export 的实际值（单引号内也能生效）
_expand_hook_vars() {
  local cmd="$1"
  local var_name value pattern

  while [[ "$cmd" =~ \$\{(hook_[^}]+)\} ]]; do
    var_name="${BASH_REMATCH[1]}"
    value="${!var_name:-}"
    pattern="\${${var_name}}"
    cmd="${cmd//$pattern/$value}"
  done
  printf '%s' "$cmd"
}

run_hook() {
  local hook_name="$1"
  local cmd rc=0 output line

  cmd="$(hook_cmd "$hook_name")"
  if [[ -z "$cmd" || "$cmd" == "null" ]]; then
    return 0
  fi

  export hook_current_time="$(TZ=Asia/Shanghai date +%Y%m%d-%H%M%S)"
  cmd="$(_expand_hook_vars "$cmd")"

  hook_log "开始执行 ${hook_name}"

  output="$(eval "$cmd" 2>&1)" || rc=$?

  if [[ -n "$output" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      hook_log "输出: ${line}"
    done <<< "$output"
  fi

  if [[ $rc -eq 0 ]]; then
    hook_log "${hook_name} 执行成功"
  else
    hook_log "${hook_name} 执行失败 (exit ${rc})"
  fi

  return 0
}

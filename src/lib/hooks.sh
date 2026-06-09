#!/usr/bin/env bash
# 部署事件钩子：读取配置、阻塞执行用户命令、记录日志（失败不中断主流程）

hook_log() {
  echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] [hook] $*" >&2
}

run_hook() {
  local hook_name="$1"
  local cmd rc=0 output line

  cmd="$(hook_cmd "$hook_name")"
  if [[ -z "$cmd" || "$cmd" == "null" ]]; then
    return 0
  fi

  export hook_current_time="$(TZ=Asia/Shanghai date +%Y%m%d-%H%M%S)"

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

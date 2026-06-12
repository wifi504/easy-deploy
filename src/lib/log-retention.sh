#!/usr/bin/env bash
# 按 logs.level 在 agent 结束时决定是否删除本次日志目录

apply_log_retention() {
  local failures="${1:-0}"
  local level
  level="$(log_level)"

  case "$level" in
    always) return 0 ;;
    deploy)
      if [[ ! -f "${LOG_DIR}/.deploy-executed" ]]; then
        log_msg "未执行任何 deploy，按 logs.level=deploy 删除本次日志目录"
        rm -rf "$LOG_DIR"
      fi
      ;;
    error)
      if [[ "$failures" -eq 0 ]]; then
        log_msg "无 worker 错误，按 logs.level=error 删除本次日志目录"
        rm -rf "$LOG_DIR"
      fi
      ;;
    *)
      die "无效的 logs.level: ${level}（允许值: always | deploy | error）"
      ;;
  esac
}

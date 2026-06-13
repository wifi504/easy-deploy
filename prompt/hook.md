# 为部署脚本支持事件钩子

部署脚本在关键时间点阻塞执行 `hooks` 段中配置的 shell 命令。完整说明与触发时机表见 [config.doc.md](../config.doc.md#部署事件钩子hooks)；执行流程见 [deploy.md](./deploy.md#事件钩子hooks)。

默认 [`easy-deploy-config.yaml`](../src/easy-deploy-config.yaml) **可不包含** hooks 段（完全可选）。

```yaml
# 部署事件钩子（可选）
# ${hook_*} 由脚本在触发时注入；hook 命令失败不会中断部署
hooks:
  on-agent-start: "echo agent-start：${hook_current_time}"
  on-agent-success: "echo agent-end，成功"
  on-agent-fail: "echo agent-end，失败了 ${hook_fail_count} 个 worker"

  on-package-start: "echo ${hook_service_name} 开始拉取新版本"
  # 将进入 deploy 时触发（含 config 变更 force 下同 version/digest）
  on-package-success: "echo ${hook_service_name} 拉取到了新制品，版本为：${hook_package_version_tag}"
  on-package-fail: "echo ${hook_service_name} 获取新制品时失败，原因是：${hook_package_errmsg}"
  # 正常 skip 时触发；force 模式不触发
  on-package-skip: "echo ${hook_service_name} 已经是最新版本，无需部署"

  on-deploy-start: "echo ${hook_service_name} 开始部署"
  on-deploy-success: "echo ${hook_service_name} 部署成功"
  on-deploy-fail: "echo ${hook_service_name} 部署失败，原因是：${hook_deploy_errmsg}"
```

## 行为要点

- **阻塞执行**：`eval` 用户命令，输出写入对应 package/deploy/agent 日志；用户命令非 0 退出**不会**导致 easy-deploy 主流程失败。
- **异步**：需用户自行在 hook 命令内后台化（如 `nohup ... &`）。
- **package skip**：`on-package-skip` 仅在正常模式（非 force）下、version/digest 未变或 digest 命中 `blocked_version_tag` 时触发；skip 后**无** deploy hook。
- **config 变更 force**：worker 检测到 `config_hash` 变化时 package 带 `force` 参数，仍触发 `on-package-success` + 全套 deploy hook，即使制品 version/digest 未变。
- **compose vs run 失败顺序**：compose 先回滚再 `on-deploy-fail`；docker-run 先 `on-deploy-fail` 再回滚（见 config.doc.md 表）。

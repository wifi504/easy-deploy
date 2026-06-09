# 为部署脚本支持事件钩子

我希望部署脚本可以在一些关键时间点回调一些功能，我们在核心配置文件加一个 hook 配置段在 logs 和 scripts 之间

你需要同步帮我改好 `config.doc.md` 并添加上合适的注释

然后默认配置文件可以不修改，因为这个hook本身以及子项就是可选的

```yaml
# 部署事件钩子，你可以在这里配置一些命令，让部署脚本发生这些事件的时候运行你自己的指令
# 在hooks配置段中，所有 ${hook_*} 格式的环境变量都会被hook执行时动态注入当前实际值
# ${hook_current_time} 可以获取触发hook时 yyyyMMdd-hhmmss 格式的时间
# ${hook_service_name} 在需要接收 serviceName 参数的脚本内可以获取传进来的 serviceName
hooks:
  # 部署Agent启动时
  on-agent-start: "echo agent-start：${hook_current_time}"
  # 部署Agent成功结束
  on-agent-success: "echo agent-end，成功"
  # 部署Agent失败结束，${hook_fail_count} 可以获取失败的 worker 数量
  on-agent-fail: "echo agent-end，失败了 ${hook_fail_count} 个 worker"
  
  # package 流程开始时
  on-package-start: "echo ${hook_service_name} 开始拉取新版本"
  # package 流程成功获取新制品时，${hook_package_version_tag} 可以获取会存入 current-versions.json 的 version_tag
  on-package-success: "echo ${hook_service_name} 拉取到了新制品，版本为：${hook_package_version_tag}"
  # package 流程获取新制品失败时，不包括版本相同跳过拉取的场景，${hook_package_errmsg} 可以获取失败的原因，每个脚本会尽可能把失败原因组装成一句话
  on-package-fail: "echo ${hook_service_name} 获取新制品时失败，原因是：${hook_package_errmsg}"
  # package 流程获取到新版本与当前一致时
  on-package-skip: "echo ${hook_service_name} 已经是最新版本，无需部署"
  
  # deploy 流程开始时
  on-deploy-start: "echo ${hook_service_name} 开始部署"
  # deploy 流程成功结束
  on-deploy-success: "echo ${hook_service_name} 部署成功"
  # deploy 流程失败结束，${hook_deploy_errmsg} 可以获取失败的原因，每个脚本会尽可能把失败原因组装成一句话
  on-deploy-fail: "echo ${hook_service_name} 部署失败，原因是：${hook_deploy_errmsg}"
```

我们单个的shell脚本内阻塞运行用户命令（如果有），日志顺便记录这个命令的全部输出，最后记录成功与否，然后我们的脚本继续执行，不能因为用户命令执行报错就导致我们shell脚本退出，如果用户自己想做耗时的命令还要异步，那他的命令可以运行一个shell，所以我们不考虑异步的情况，这种场景就交给用户自己了


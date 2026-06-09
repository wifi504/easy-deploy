# Easy Deploy Config 文档

默认的配置文件请查看 [easy-deploy-config.yaml](./src/easy-deploy-config.yaml)

## 配置文件整体结构

```yaml
# 配置Gitea的访问方式
gitea:
  # 访问 Gitea 的方式，建议配好网络都走内网
  url: http://10.10.10.11:10088
  # token 支持两种写法：
  # 1. ${GITEA_TOKEN} 从环境变量读取（推荐，token 不进 git）
  # 2. 直接写明文 token 字符串
  token: ${GITEA_TOKEN}

# 日志
logs:
  # logs目录下滚动覆盖，只保留最新的多少次执行的日志，配置为0时，不保留日志，配置为-1时，无上限
  max-log-history: 10

# 部署事件钩子（可选，默认配置文件可不包含此段）
# 在关键时间点阻塞执行配置的 shell 命令；hook 命令失败不会中断部署流程
# 所有 ${hook_*} 格式的变量在 hook 执行时动态注入；耗时任务请用户自行后台化
hooks:
  # 部署 Agent 启动时
  on-agent-start: "echo agent-start：${hook_current_time}"
  # 部署 Agent 成功结束（全部 worker 成功）
  on-agent-success: "echo agent-end，成功"
  # 部署 Agent 失败结束，${hook_fail_count} 为失败的 worker 数量
  on-agent-fail: "echo agent-end，失败了 ${hook_fail_count} 个 worker"
  # package 流程开始时
  on-package-start: "echo ${hook_service_name} 开始拉取新版本"
  # package 成功获取新制品，${hook_package_version_tag} 为将写入 current-versions.json 的版本
  on-package-success: "echo ${hook_service_name} 拉取到了新制品，版本为：${hook_package_version_tag}"
  # package 获取新制品失败（不含版本相同跳过），${hook_package_errmsg} 为失败原因
  on-package-fail: "echo ${hook_service_name} 获取新制品时失败，原因是：${hook_package_errmsg}"
  # package 检测到版本与当前一致
  on-package-skip: "echo ${hook_service_name} 已经是最新版本，无需部署"
  # deploy 流程开始时
  on-deploy-start: "echo ${hook_service_name} 开始部署"
  # deploy 流程成功结束
  on-deploy-success: "echo ${hook_service_name} 部署成功"
  # deploy 流程失败，${hook_deploy_errmsg} 为失败原因
  on-deploy-fail: "echo ${hook_service_name} 部署失败，原因是：${hook_deploy_errmsg}"

# 脚本运行所需的一些配置
scripts:
  # Nginx Reload 命令（存在 frontend-dist 服务时必填）
  reload-nginx-cmd: "docker exec nginx-container nginx -s reload"

# CD 流程要处理的服务，是个数组
services:

  - name: service1
    package: ...
    deploy: ...

  - name: service2
    package: ...
    deploy: ...

  - name: service3
    package: ...
    deploy: ...
```

## 服务配置

- 每一个 service 就是部署脚本后台并行单独处理的一个任务

- name：这个任务在配置文件里的唯一标识，不可重复，也是日志文件记录会引用的文件名，所以不可以有文件名不能用的符号
- package：定义制品的获取流程
- deploy：定义获取到的制品怎么部署
- package 和 deploy 配置段有对应关系，区分方式就是 package 的 type 和 deploy 的 strategy，现版本支持的配置对应方式如下
  - package.type=generic -> deploy.strategy=frontend-dist
  - package.type=docker-container -> deploy.strategy=docker-compose
  - package.type=docker-container -> deploy.strategy=docker-run （敬请期待...）

**以下是配置段参考：**

### 拉取《通用制品》 -> 部署《指定 Nginx 文件夹》

`package.type=generic -> deploy.strategy=frontend-dist`

```yaml
package:
  type: generic
  owner: gitea-package所有者名字
  name: gitea-package名字
  file: 制品文件的名字
deploy:
  strategy: frontend-dist
  target: 解压缩制品文件的目标目录
```



### 拉取《Docker 镜像》 -> 部署《Docker 编排》

`package.type=docker-container -> deploy.strategy=docker-compose`

```yaml
package:
  type: docker-container
  owner: gitea-package所有者名字
  name: gitea-package名字
deploy:
  strategy: docker-compose
  compose: dockercompose文件的路径/docker-compose.yml
  service: compose文件里面的service名字
  started-check-seconds: 容器启动后，等待多少秒，看下这个容器有没有停止或者重启过
```

## 部署事件钩子（hooks，可选）

`hooks` 段及所有子项均为可选；默认 [`easy-deploy-config.yaml`](./src/easy-deploy-config.yaml) 不含此段。

在配置文件中放在 `logs` 与 `scripts` 之间。部署脚本在对应事件发生时**阻塞**执行配置的 shell 命令（`eval`），命令的全部输出写入对应阶段日志；hook 命令失败**不会**中断部署主流程。若需耗时或异步任务，请在 hook 命令内自行后台启动子 shell。

### Hook 名称

| Hook | 触发时机 |
|------|----------|
| `on-agent-start` | Agent 启动后、启动 worker 前 |
| `on-agent-success` | 全部 worker 成功且 temp 清理后 |
| `on-agent-fail` | 存在 worker 失败且 temp 清理后 |
| `on-package-start` | 单个 service 的 package 流程开始 |
| `on-package-success` | 成功拉取到新制品 |
| `on-package-fail` | 拉取新制品失败（不含版本相同跳过） |
| `on-package-skip` | 检测到版本与当前一致，跳过部署 |
| `on-deploy-start` | 单个 service 的 deploy 流程开始 |
| `on-deploy-success` | deploy 成功结束 |
| `on-deploy-fail` | deploy 失败结束 |

### 动态变量（`${hook_*}`）

| 变量 | 适用 Hook |
|------|-----------|
| `${hook_current_time}` | 全部；格式 `yyyyMMdd-HHmmss`（Asia/Shanghai） |
| `${hook_service_name}` | service 级 hook（package / deploy） |
| `${hook_fail_count}` | `on-agent-fail` |
| `${hook_package_version_tag}` | `on-package-success`；generic 为 Gitea version，docker-container 为 `sha256:...` digest |
| `${hook_package_errmsg}` | `on-package-fail` |
| `${hook_deploy_errmsg}` | `on-deploy-fail` |

用户命令中其他已 export 的环境变量（如 `${GITEA_TOKEN}`）同样可在 hook 命令中使用。
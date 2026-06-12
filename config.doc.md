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
  # 日志保留级别：always: 每次保留 | deploy: 有deploy执行才保留（默认）| error: 有worker错误才保留
  level: deploy

# 部署事件钩子（可选）
hooks:
  # 部署 Agent 启动时
  on-agent-start: "echo agent-start：${hook_current_time}"
  # ... 更多配置详见下文 hooks 小节

# 脚本运行所需的一些配置
scripts:
  # Nginx Reload 命令（存在 frontend-dist 服务时必填）
  reload-nginx-cmd: "docker exec nginx-container nginx -s reload"
  # compose worker package 超时 / daemon 屏障等待上限（秒，默认 60）
  package-timeout-seconds: 60
  # compose deploy 客户端入队到收到响应的超时（秒，默认 120）
  deploy-timeout-seconds: 120

# CD 流程要处理的服务，是个数组，具体配置详见下文 services 小节
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



## 日志（logs）

- `max-log-history`：在每次执行**开始**时，对 `logs/deploy-*` 目录做滚动清理（0 = 不保留历史；−1 = 无上限；N = 只保留最新 N 个目录）。
- `level`：日志保留级别，默认 `deploy`。执行期间日志照常写入；仅在 agent **结束**时判断是否删除本次 `deploy-*` 目录。

| level | 含义 |
|-------|------|
| `always` | 每次执行都保留日志目录 |
| `deploy` | 至少有一个 service 实际进入 deploy 流程才保留；全部 skip 或仅 package 失败时删除 |
| `error` | 至少有一个 worker 失败才保留；全部 worker 成功时删除 |

`max-log-history` 与 `level` 配合使用：例如 `max-log-history: 10` 且 `level: deploy` 时，磁盘上最多保留最近 10 次**实际执行过 deploy** 的运行日志，适合定时任务频繁触发、多数运行无实际部署的场景。



## 服务配置（services）

- 每一个 service 就是部署脚本后台并行单独处理的一个任务

- name：这个任务在配置文件里的唯一标识，不可重复，也是日志文件记录会引用的文件名，所以不可以有文件名不能用的符号
- package：定义制品的获取流程；**一个制品只能对应一个 service 配置段**——`docker-container` 按 `owner`+`name` 全局唯一，`generic` 按 `owner`+`name`+`file` 全局唯一
- deploy：定义获取到的制品怎么部署
- package 和 deploy 配置段有对应关系，区分方式就是 package 的 type 和 deploy 的 strategy，现版本支持的配置对应方式如下
  - package.type=generic -> deploy.strategy=frontend-dist
  - package.type=docker-container -> deploy.strategy=docker-compose
  - package.type=docker-container -> deploy.strategy=docker-run

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
  started-check-seconds: 3
```

`started-check-seconds` 说明：部署后等待指定秒数，检查容器是否仍在运行且未发生重启；配置为 `-1` 时跳过该检查，启动成功即视为部署成功。`docker-compose` 与 `docker-run` 均适用。多个 compose service 共享同一 yml 时，daemon 会对 batch 内各 service 的 `started-check-seconds` 做**升序阶梯**检查（例如 3 与 5 分别在第 3、5 秒检查对应 service）；`-1` 不参与等待。

多个 easy-deploy service 可指向**同一** `deploy.compose` 文件，但 **`deploy.compose` + `deploy.service` 组合全局唯一**（同一 compose 文件内不同 service 名须分别配置）。

`docker-compose` 策略下，worker 的 deploy 步骤为薄客户端（入队 + 阻塞等待）；同 compose 文件的多个 digest service 由 **Compose Deploy Daemon** 批处理：一次 patch image、`docker compose up -d --no-deps --force-recreate`，失败时原子回滚整批。

### 拉取《Docker 镜像》 -> 部署《Docker Run》

`package.type=docker-container -> deploy.strategy=docker-run`

同一镜像可配置**多个容器实例**：`deploy.containers` 为数组，每项对应一次 `docker run`。脚本按数组顺序逐个部署；任一实例失败则**全量回滚**（所有实例恢复旧 digest）。镜像地址由 Gitea 配置与 package digest 拼接，**不必在配置里写镜像**；`-d`（后台运行）由脚本默认添加。

每项的 `options`、`command`、`args` 对应 `docker run [OPTIONS] IMAGE [COMMAND] [ARG...]` 中 IMAGE 之前/之后的部分；`options` 必填，`command` 与 `args` 可选。均支持 YAML 字符串数组或 `>-` 折叠块。

每项 `options` 中必须包含 `--name`（或 `--name=xxx`），用于定位容器、部署前 `docker rm -f` 及**跨 service 全局**唯一性校验。

```yaml
package:
  type: docker-container
  owner: gitea-package所有者名字
  name: gitea-package名字
deploy:
  strategy: docker-run
  started-check-seconds: 5
  containers:
    - options: >-
        --name my-api-1
        -p 8080:8080
        -e SPRING_PROFILES_ACTIVE=prod
      command: java
      args: >-
        -jar /app/app.jar
    - options: ["--name", "my-api-2", "-p", "8081:8080"]
      command: ["java"]
      args: ["-jar", "/app/app.jar"]
```

单容器时 `containers` 仍须为数组（至少 1 项）。



## 部署事件钩子（hooks）

**`hooks` 段及所有子项均为可选**；默认 [`easy-deploy-config.yaml`](./src/easy-deploy-config.yaml) 不含此段。

在配置文件中放在 `logs` 与 `scripts` 之间。部署脚本在对应事件发生时**阻塞**执行配置的 shell 命令（`eval`），命令的全部输出写入对应阶段日志；hook 命令失败**不会**中断部署主流程。若需耗时或异步任务，请在 hook 命令内自行后台启动子 shell。

完整的hooks配置如下

```yaml
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
```

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
| `${hook_package_version_tag}` | `on-package-success`、`on-deploy-start` 及 deploy 阶段 hook；generic 为 Gitea version，docker-container 为 `sha256:...` digest |
| `${hook_package_errmsg}` | `on-package-fail` |
| `${hook_deploy_errmsg}` | `on-deploy-fail` |

用户命令中其他已 export 的环境变量（如 `${GITEA_TOKEN}`）需在 shell 双引号或未引号语境下才会被 `eval` 展开；`${hook_*}` 则在执行前由脚本直接替换，**单引号内也可使用**。

### 多行命令（YAML `>-`）

Hook 的值是普通 YAML 字符串，支持用 **`>-` 折叠块** 写多行命令：换行会被折叠成空格，末尾换行会被去掉，最终仍作为**一条 shell 命令**执行。适合较长的 `curl`、带多个参数的命令等，不必挤在一行引号里。

```yaml
hooks:
  on-deploy-start: >-
    curl --request POST
    --url 'http://10.10.10.13:10066/api/message/send?botNames=mybot&receives=group'
    --header 'Authorization: token ${BOT_TOKEN}'
    --header 'Content-Type: application/json'
    --data '{"message":"🚀 开始部署\n服务：${hook_service_name}\n时间：${hook_current_time}\n版本：${hook_package_version_tag}"}'
```

说明：

- `>-` 折叠后等价于一行：`curl --request POST --url '...' --header '...' ...`
- `${hook_*}` 在 JSON 单引号内也会正确替换；敏感 token 建议写成 `${BOT_TOKEN}`，运行前 `export BOT_TOKEN=...`
- 单行写法 `"echo ..."` 与 `>-` 多行写法可混用，按可读性选择即可

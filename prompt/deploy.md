## 整个部署脚本的结构

仓库内脚本根目录为 **`src/`**（运行时 `DEPLOY_ROOT`，需在 `src/` 下执行命令）。以下路径均相对于 `src/`：

```text
src/
├── easy-deploy.sh
├── easy-deploy-config.yaml
├── install.sh
├── uninstall.sh
├── lib/
│   ├── logging.sh
│   ├── config.sh
│   ├── lock.sh
│   ├── versions.sh
│   ├── compose-deploy-ipc.sh
│   └── validate.sh
├── data/
│   ├── easy-deploy.lock
│   ├── current-versions.json
│   └── temp/
│       └── 脚本执行期间的临时文件
├── scripts/
│   ├── easy-deploy-agent.sh
│   ├── easy-deploy-worker.sh
│   ├── package-generic.sh
│   ├── package-docker-container.sh
│   ├── deploy-frontend-dist.sh
│   ├── deploy-docker-compose.sh
│   ├── deploy-docker-compose-stack.sh
│   ├── compose-deploy-daemon.sh
│   └── deploy-docker-run.sh
└── logs/
    └── deploy-20260102-121233/
        ├── easy-deploy.sh.log
        ├── easy-deploy-agent.sh.log
        ├── easy-deploy-worker.sh.{services对应的name}.log
        ├── package-generic.sh.{services对应的name}.log
        ├── package-docker-container.sh.{services对应的name}.log
        ├── deploy-frontend-dist.sh.{services对应的name}.log
        ├── deploy-docker-compose.sh.{services对应的name}.log
        ├── compose-deploy-daemon.sh.log
        └── （命名风格：执行的 shell 文件名 + 可区分 key + .log）
```

## 运行环境

目标平台是 **Linux + Bash 4+**。

脚本依赖以下命令，首次部署前在 `src/` 下运行 `./install.sh` 安装（`install.sh` 会自动检测 apt 或 yum/dnf，用系统包管理器安装；`docker` 和 `docker compose` 只检测并提示，不自动安装，避免改动过大）。卸载依赖用 `./uninstall.sh`，会逐个包询问 y/n，避免误删其他脚本还在用的东西。

- curl、jq、yq
- unzip、tar、7z（p7zip）
- docker、docker compose（V2 子命令，形如 `docker compose up -d`，不使用旧版 `docker-compose` 独立程序）

## 执行逻辑

### 配置

easy-deploy-config.yaml 是部署脚本的核心配置文件，长相如下

```yaml
# 配置Gitea的访问方式
gitea:
  url: http://10.10.10.11:10088
  # token 支持两种写法：
  # 1. ${GITEA_TOKEN}  —— 从环境变量读取（推荐，token 不进 git）
  # 2. 直接写明文 token 字符串
  token: ${GITEA_TOKEN}

# 日志
logs:
  max-log-history: 10 # logs目录下滚动覆盖，只保留最新的多少次执行的日志，配置为0时，不保留日志，配置为-1时，无上限

# 脚本运行所需的一些配置
scripts:
  # Nginx Reload 命令
  reload-nginx-cmd: "docker exec nginx-webui nginx -s reload"
  # compose package / daemon 屏障等待（秒，默认 60）
  package-timeout-seconds: 60
  # compose deploy 客户端等待 daemon 响应（秒，默认 120）
  deploy-timeout-seconds: 120

# CD流程要处理的服务
services:

  - name: frontend-admin # 名称
    # package的访问方式
    package:
      owner: Troy
      type: generic
      name: my-frontend-admin
      file: dist.zip
    # 部署的方式
    deploy:
      strategy: frontend-dist
      target: /data/nginx/web/my_website # frontend-dist模式下，会把 dist.zip 覆盖的位置

  - name: order-service
    package:
      owner: Troy
      type: docker-container
      name: my-order-service
    deploy:
      strategy: docker-compose
      compose: /data/docker/compose/order-service/docker-compose.yml
      service: order-service
      started-check-seconds: 3
```

`services.package.type` 支持 `generic | docker-container`，`services.deploy.strategy` 支持 `frontend-dist | docker-compose | docker-run`

**type 与 strategy 强制配对**（不允许随意排列组合）：

- `generic` 必须配 `frontend-dist`
- `docker-container` 必须配 `docker-compose` 或 `docker-run`

配对不对的话，入口校验直接报错退出。

### 关于日志

每次运行 easy-deploy.sh，也就是从入口进去，先在 `./logs/` 创建一个格式为 `deploy-20260102-121233` 的目录，日期时间用 **UTC+8 中国时间**（`TZ=Asia/Shanghai`）。

**easy-deploy.sh 必须无参直接运行**，不然就不 easy 了。

日志采集方式：公共 `lib/logging.sh`，各脚本启动时 `source` 后通过 `exec tee` 把 stdout 和 stderr 同时写到对应 log 文件。父进程只需 `export LOG_DIR`（以及 worker 场景下的 `SERVICE_NAME`），子脚本自动按「执行的 shell 文件名 + 区分 key + .log」规则写入，具体存的就是整个执行期间所有 shell 脚本要打印的所有东西。

创建本次 log 目录后，立刻按 `logs.max-log-history` 滚动清理旧的 `deploy-*` 目录（0 = 不保留历史；−1 = 无上限；N = 只保留最新 N 次）。

### 关于版本

`./data/current-versions.json` 这个文件记录了配置文件里每个 service 现在实际跑着的版本。

**初始化**：文件不存在时，按 config 里所有 `service.name` 自动创建，`version_tag` 默认为空字符串；文件已存在时，合并新增的 service、保留已有 version。

**并发更新**：agent 并行启动多个 worker，更新 json 时对文件加 `flock` 锁，读-改-写-解锁。

**version_tag 存什么**：

- `generic` 类型：存 Gitea 制品的 version 字符串
- `docker-container` 类型：存完整 Digest，形如 `sha256:ca50457390a9eaa77abb7d7dff829f594db96fd2c0bc3901a7797b6fcc23ff19`

结构如下

```json
{
    "frontend-admin": {
        "version_tag": ""
    },
    "order-service": {
        "version_tag": ""
    },
    "其他service的名字": {
        "version_tag": ""
    }
}
```

## easy-deploy.sh

easy-deploy.sh 是主入口，可以一次性执行，也可以扔到定时任务里去。**只支持无参运行**。

这个脚本干两件事：

**Step1. 执行 `easy-deploy-config.yaml` 校验**

为了尽可能防止意外，先做有效性校验

- gitea 能否访问的通，token是否有效

- package的type和deploy的strategy是不是现在版本所支持的

- type 与 strategy 是否强制配对（generic→frontend-dist，docker-container→docker-compose 或 docker-run）

- services 非空；各 service 必填字段完整（generic 必须有 `package.file`）

- package 全局唯一：`docker-container` 按 `owner`+`name`；`generic` 按 `owner`+`name`+`file`

- service的name是不是文件系统允许的文件名（因为日志要引用这个，规则：`^[a-zA-Z0-9._-]+$`）

- service的name是否存在重复

- 所有的 `deploy.strategy=frontend-dist` 的service的 `deploy.target` 是否存在重复

- 所有的 `deploy.strategy=docker-compose` 的 service：`deploy.compose` + `deploy.service` 组合全局唯一（允许多个 service 共享同一 compose 文件路径）

- 所有的 `deploy.strategy=docker-run` 的 service：`deploy.containers` 为非空数组，每项 `options` 含 `--name`，容器名全局不重复

- `scripts.package-timeout-seconds` / `scripts.deploy-timeout-seconds` 若配置则须为正整数

- 所有的 `deploy.target` 是不是一个有效的目录，且可写

- 所有的 `deploy.compose` 指向的 `docker-compose.yml` 存在且里面找得到 `deploy.service` 的那个 service

- `deploy.started-check-seconds` 为正整数或 `-1`（禁用稳定性检查）

- 存在 `frontend-dist` 服务时，`scripts.reload-nginx-cmd` 非空

- 依赖命令存在：curl、jq、yq、docker、`docker compose`、unzip、tar、7z

- `data/`、`logs/` 目录可创建

没有通过有效性检查的话，此脚本直接报错退出，然后要把没通过的原因打出来

**Step2. 启动 `easy-deploy-agent.sh`**

若要启动部署流程，必须先在 `./data` 创建 `easy-deploy.lock` 文件，然后用 Linux **`flock -n` 非阻塞文件锁** 锁定这个文件（标准机制，保证同一时刻只有一个 agent 在跑）。

如果拿不到锁（已有实例在运行），则脚本直接结束。

**锁残留**：agent 正常或异常退出时 flock 随进程释放；若 lock 文件残留（例如机器断电），需手动删除 `data/easy-deploy.lock`。不做 stale 自动检测。

拿到锁，开始执行之后，就可以后台运行 `easy-deploy-agent.sh` 了，也就是说，如果我前台终端手动运行 `easy-deploy.sh`，到这里看到成功开始执行自动化部署字样之后，就退出了

## easy-deploy-agent.sh

通过了入口，创建了后台进程，才开始正式走这个脚本的流程：

1. `compose_ipc_init` 初始化 `${TEMP_DIR}/compose-deploy/` IPC 目录
2. 若配置中存在 `docker-compose` 策略的 service，**后台启动** `compose-deploy-daemon.sh`
3. 读取 `./easy-deploy-config.yaml` 里所有 `services` 的 `name`，并行启动 `easy-deploy-worker.sh`
4. **等待全部 worker** 结束（失败计入 failures）
5. 若曾启动 daemon：写入 `daemon.shutdown`，**wait** daemon 进程退出
6. 清空 `./data/temp/`，释放锁，执行 agent 级 hook 与日志保留

**某个 worker 失败不影响其他 worker**，各 service 独立并行；compose deploy 由 daemon 按 compose 文件批处理，同文件 sibling package 失败会导致已入队的 digest job 收到 deploy 失败。

所有 worker 与 daemon 结束后，sweep 整个 `./data/temp/` 目录（含 compose-deploy IPC），然后释放 easy-deploy.lock。

## easy-deploy-worker.sh

**此脚本执行必要的入参依次：`serviceName`**

读取 `./easy-deploy-config.yaml` 里的 services 的name是入参的那一项

**Step1. 执行 package 逻辑**

如果type是 generic，把 serviceName 传给 `package-generic.sh` 执行，阻塞等待返回值

如果type是 docker-container，把 serviceName 传给 `package-docker-container.sh` 执行，阻塞等待返回值

**Step2. 执行 deploy 逻辑**

首先，Step1得成功，失败的话就不执行了，此脚本报错结束

其次，Step1成功后，判断返回值如果是 `skip_deploy`，此脚本正常结束（不会进入 deploy，因此 frontend-dist 也不会触发 nginx reload）

如果strategy是 frontend-dist，把 serviceName 和 package 步骤返回值 传给 `deploy-frontend-dist.sh` 执行

如果strategy是 docker-compose，worker 在 package 后写 compose status（skip/fail/digest）；digest 时把 serviceName 和 digest 传给 `deploy-docker-compose.sh`（薄客户端：入队 + `on-deploy-start` + 阻塞等待 daemon 结果）

如果strategy是 docker-run，把 serviceName 和 package 步骤返回值 传给 `deploy-docker-run.sh` 执行

**package 返回值约定**（供 worker 解析）：

- `skip_deploy`：版本未变，整行输出此字符串
- generic 成功：stdout 最后一行是制品绝对路径，倒数第二行是 version 字符串
- docker-container 成功：stdout 最后一行是 Digest 字符串

## package-generic.sh

**此脚本执行必要的入参依次：`serviceName`**

读取 `./easy-deploy-config.yaml` 的 service的name等于serviceName的那个配置的package段

**Step1. 找最新**

先找最新的制品version（给你提供curl参考）

```bash
curl -H "Authorization: token ${gitea.token}" \
  "${gitea.url}/api/v1/packages/${package.owner}/generic/${package.name}/-/latest"
```

这会得到一个 JSON 对象，直接提取 `$.version` 字段，这个就是version

无法获取version，此脚本直接报错结束

如果获取到了version，马上和 `current-versions.json` 里的记录做比对，如果相同，此脚本正常结束，返回 `skip_deploy`

**Step2. 拉最新**

查到版本号且不一样的时候，请求制品文件（给你提供curl参考）

```bash
curl -H "Authorization: token ${gitea.token}" \
  "${gitea.url}/api/packages/${package.owner}/generic/${package.name}/${前面找到的latest的version}/${package.file}"
```

然后给他存到 temp 目录下，格式为 `./data/temp/随机一个uuid/${package.file}` ，

倒数第二行输出 version，最后一行输出这个存储的绝对路径

## package-docker-container.sh

**此脚本执行必要的入参依次：`serviceName`**

读取 `./easy-deploy-config.yaml` 的 service的name等于serviceName的那个配置的package段

**Step1. 拉最新**

运行pull命令，把远程镜像拉到本地：

```bash
docker pull ${gitea.url去掉前面的http://或https://}/${package.owner}/${package.name}:latest
```

这会得到类似如下的结果：

```
root@prod-test:~/.docker# docker pull 10.10.10.11:10088/pingworth-oc/go-oc-server:latest
latest: Pulling from pingworth-oc/go-oc-server
e24aed92b4e8: Pull complete 
418d4006c386: Pull complete 
Digest: sha256:ca50457390a9eaa77abb7d7dff829f594db96fd2c0bc3901a7797b6fcc23ff19
Status: Downloaded newer image for 10.10.10.11:10088/pingworth-oc/go-oc-server:latest
10.10.10.11:10088/pingworth-oc/go-oc-server:latest
root@prod-test:~/.docker# docker pull 10.10.10.11:10088/pingworth-oc/go-oc-server:latest
latest: Pulling from pingworth-oc/go-oc-server
Digest: sha256:ca50457390a9eaa77abb7d7dff829f594db96fd2c0bc3901a7797b6fcc23ff19
Status: Image is up to date for 10.10.10.11:10088/pingworth-oc/go-oc-server:latest
10.10.10.11:10088/pingworth-oc/go-oc-server:latest
```

无法成功pull，此脚本直接报错结束

如果成功pull，从输出解析 `Digest: sha256:...`（或用 `docker inspect` 兜底），马上和 `current-versions.json` 里的记录做比对，如果相同，此脚本正常结束，返回 `skip_deploy`

**Step2. 删除旧的**

成功拉取新镜像之后，删除同一 repo（`${host}/${owner}/${name}`）下，**除了「刚 pull 的新 digest」和「current-versions.json 记录的旧 digest 对应镜像」以外**的所有本地镜像

最后一行输出这个新的 Digest

## deploy-frontend-dist.sh

**此脚本执行必要的入参依次：`serviceName`、`tempFile`、`version`**

读取 `./easy-deploy-config.yaml` 的 service的name等于serviceName的那个配置的deploy段

**Step1. 解压新文件到临时目录**

先判断入参传进来的 `tempFile` 是什么格式的压缩包，然后用正确的方式解压到 `./data/temp/再随机一个uuid/` 里面

支持的格式：`*.zip`、`*.7z`、`*tar.gz`

判断解压成功了吗，如果失败，则删掉 `tempFile` 对应的那个目录和刚刚临时解压的那个目录，此脚本直接报错退出（判断解压成功就是从解压程序的返回值判断，如果没问题，再判断这个临时目录是否为空，如果为空也认为是失败情况）

**Step2. 删除旧文件**

把 `${deploy.target}` 这个目录清空，不删除目录本身

可能因为权限之类的清空失败，删掉 `tempFile` 对应的那个目录和刚刚临时解压的那个目录，此脚本直接报错结束

**Step3. 移动文件，更新标记**

把临时目录里的所有文件 mv 到 `${deploy.target}`里面，删掉 `tempFile` 对应的那个目录和刚刚临时解压的那个目录

把 `current-versions.json` 对应的 `version_tag` 更新为入参 `version`（flock 读-改-写）

**Step4. Nginx Reload**

运行配置文件里的 `scripts.reload-nginx-cmd`

只有真正执行了 deploy 才会 reload；package 返回 `skip_deploy` 时 worker 不会调用本脚本，因此不会 reload

## deploy-docker-compose.sh

**此脚本为薄客户端**，入参不变：`<serviceName> <imageDigest>`。

1. `compose_job_submit` 写入 pending job 并通知 daemon
2. **立即**触发 `on-deploy-start`
3. `compose_job_wait` 阻塞直至 daemon 写回 `responses/<jobId>`（受 `scripts.deploy-timeout-seconds` 约束，默认 120s）
4. 成功 exit 0 并 touch `.deploy-executed`；失败 exit 1

**不再**直接改 yml 或执行 `docker compose`。批处理由 `compose-deploy-daemon.sh` 调用 `deploy-docker-compose-stack.sh` 完成：

- 同 compose 文件的全部 digest service 一次 patch image + `docker compose up -d --no-deps --force-recreate`
- 升序阶梯稳定性检查（batch 内各 service 的 `started-check-seconds`；`-1` 跳过）
- 失败时**原子回滚**整批（恢复 yml、旧 digest recreate、删新镜像），batch 内全部 job 返回失败 + `on-deploy-fail`
- 同文件 sibling package 失败或屏障超时：已入队 job 收到 deploy 失败，不调用 stack

Hook：`on-deploy-start` 在客户端入队时；`on-deploy-success` / `on-deploy-fail` 在 daemon 写 response 前（按 job 的 service 触发）。

## compose-deploy-daemon.sh

Agent 在有 compose service 时后台启动。主循环读 `inbox.fifo`，按 `composeFile` 触发 `process_compose_file`（同文件 processing 锁，不同文件可并行）。

屏障条件：同文件全部 easy-deploy service 已有 package status，且所有 `status=digest` 的 service 均已入队。等待上限为 `scripts.package-timeout-seconds`（默认 60）。

Agent 在全部 worker 结束后写入 `daemon.shutdown` 并 wait daemon 退出。

## deploy-docker-run.sh

**此脚本执行必要的入参依次：`serviceName`、`imageDigest`**

读取配置中 `deploy.containers` 数组，**按顺序**对每个容器实例执行：停止旧容器 → `docker run -d` 新 digest → 稳定性检查。

**配置结构**：`deploy.started-check-seconds` 与 `deploy.containers` 同级；每项含 `options`（必填，须含 `--name`）、`command`（可选）、`args`（可选）。详见 [docker-run-multi.plan.md](./docker-run-multi.plan.md)。

**失败回滚（原子语义）**：任一实例 run 失败或稳定性检查失败 → 删除本 service 全部容器 → 若有旧 digest 则按 `containers` 顺序用旧 digest 重启全部实例 → 删除新 digest 镜像 → 报错退出。

**成功**：全部实例通过后更新 `current-versions.json`，删除旧 digest 镜像。

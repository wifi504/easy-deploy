# Easy Deploy!

让运维更简单 - 可以自动化完成前后端制品部署的 CD 流程 Shell 脚本

## 项目结构介绍

此项目也算是 Vibe Coding 的一个小实践，`AI Rate > 90%`

仓库分两块：

- **`prompt/`**：生成运维脚本的提示词文档和 plan 文档
- **`src/`**：部署到服务器的脚本（Release 打包的目录）

在部署机上看到的目录，解压后结构如下（就是 `src/` 里的内容）：

```text
easy-deploy/
├── easy-deploy.sh              # 入口
├── easy-deploy-config.yaml     # 核心配置
├── install.sh                  # 装依赖，并注册 easy-deploy 命令
├── uninstall.sh                # 先取消命令注册，再逐项 y/n 卸依赖
├── lib/                        # 公共库（日志、配置、锁、版本、校验）
├── scripts/                    # agent / worker / package / deploy
├── data/                       # 运行时生成（lock、版本记录、临时文件）
└── logs/                       # 每次执行的日志目录
```

`data/` 和 `logs/` 不会进 git，第一次跑脚本时会自动创建。

## 使用方式

### 安装

在部署机上，随便找个目录，推荐 `/opt/` ，直接使用如下命令下载最新版本到当前目录的 `easy-deploy/`：

```bash
curl -fsSL -o easy-deploy.tar.gz https://github.com/wifi504/easy-deploy/releases/latest/download/easy-deploy.tar.gz && mkdir -p easy-deploy && tar -xzf easy-deploy.tar.gz -C easy-deploy && rm -f easy-deploy.tar.gz
```

下载完成后进入目录：

```bash
cd easy-deploy
bash install.sh
```

`install.sh` 会安装依赖，并把 `easy-deploy` 注册到 `/usr/local/bin/`（以后任意目录可直接跑 `easy-deploy`）。同时会在同目录生成 `install.info`，记录安装前机器上已有的依赖；卸载时会自动跳过这些包。

### 卸载

非常绿色的运维脚本，想卸依赖用 `bash uninstall.sh`，会先取消 `easy-deploy` 命令注册，再逐个包问你删除吗 y/n，避免误删你在使用此运维脚本后，自己写了别的脚本，用到的一些相同依赖。

最后，如果彻底不想要了，把 `easy-deploy` 这个目录删掉即可。

### 更新

一般情况下不需要更新，**除非遇到了严重的 bug，请提 issue**。

`data/` 可选备份：主要是已部署版本的记录，删掉后下次运行会视作所有任务都要重新跑一遍；一般只保留 `easy-deploy-config.yaml` 即可。

在**部署目录的上一级**（例如 `/opt/`，与初次安装时相同）执行以下命令，可**保留配置并更新脚本到最新版**；`uninstall.sh` 会逐项询问 y/n，按提示选择即可：

```bash
cd easy-deploy
bash uninstall.sh
mv easy-deploy-config.yaml ../
cd ..
rm -rf easy-deploy
curl -fsSL -o easy-deploy.tar.gz https://github.com/wifi504/easy-deploy/releases/latest/download/easy-deploy.tar.gz && mkdir -p easy-deploy && tar -xzf easy-deploy.tar.gz -C easy-deploy && rm -f easy-deploy.tar.gz
cd easy-deploy
bash install.sh
mv ../easy-deploy-config.yaml .
```

若要安装**指定版本**，把上面 `curl` 里的 `latest` 换成 release Tag，例如 `release-99`：

```bash
curl -fsSL -o easy-deploy.tar.gz https://github.com/wifi504/easy-deploy/releases/download/release-99/easy-deploy.tar.gz && mkdir -p easy-deploy && tar -xzf easy-deploy.tar.gz -C easy-deploy && rm -f easy-deploy.tar.gz
```

### 配置

1. 编辑 `easy-deploy-config.yaml`，详见 [Easy Deploy Config 文档](./config.doc.md)
2. 若 token 写的是 `${GITEA_TOKEN}`，先 `export GITEA_TOKEN=你的token`
3. docker 要 `docker login` 到你的 Gitea 制品库
4. Gitea 的接口自己请求一下看看通不通，一般没问题，只要 Token **放开所有的 `读` 和 package 的 `读/写`**

### 运行

```bash
easy-deploy
```

就这一条，如此 Easy！运行后会**回到命令行**（部署在后台执行），并打印本次日志目录，例如：

```text
[2026-06-09 10:42:00] 已成功开始执行自动化部署，日志目录：/opt/easy-deploy/logs/deploy-20260609-104200
```

Agent 及各 service 的 worker / package / deploy 日志都在该 `deploy-*` 目录下。

**Tips：手动运行部署脚本能正常工作以后，可以添加到定时任务自动化执行**

## 特别说明

- **运行环境**：Linux + Bash 4+，依赖 curl、jq、yq、unzip、tar、7z、docker、docker compose（V2）
- **并发**：同一时刻只会有一个部署流程在跑（flock 锁）；如果拿不到锁，说明后台有部署脚本在运行
- **锁残留**：脚本进程被杀、机器断电之类的情况，可能留下 `data/easy-deploy.lock`，删了这个文件再跑就行
- **版本跳过**：制品版本没变会返回 `skip_deploy`，不会重复部署，也不会 reload nginx

## 开源协议

本项目采用 [MIT License](LICENSE) 开源。

Copyright (c) 2026 WIFI连接超时


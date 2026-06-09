# Easy Deploy!

让运维更简单 - 可以自动化完成前后端制品部署的 CD 流程 Shell 脚本

## 项目结构介绍

这个仓库分两块：

- **`prompt/`**：设计文档，怎么跑、怎么配，写在这里
- **`src/`**：真正要部署到机器上的脚本（Release 里打包的就是这一坨）

你在部署机上看到的目录，解压后长这样（就是 `src/` 里的东西）：

```text
easy-deploy/
├── easy-deploy.sh              # 入口，无参直接跑
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

在部署机上，随便找个目录，一条命令把最新版拉下来：

```bash
curl -fsSL -o easy-deploy.tar.gz https://github.com/wifi504/easy-deploy/releases/latest/download/easy-deploy.tar.gz && mkdir -p easy-deploy && tar -xzf easy-deploy.tar.gz -C easy-deploy && rm -f easy-deploy.tar.gz
```

解压完成后进入目录：

```bash
cd easy-deploy
./install.sh
```

`install.sh` 会安装依赖，并把 `easy-deploy` 注册到 `/usr/local/bin/`（以后任意目录可直接跑 `easy-deploy`）。同时会在同目录生成 `install.info`，记录安装前机器上已有的依赖；卸载时会自动跳过这些包。

### 配置

1. 编辑 `easy-deploy-config.yaml`，把 Gitea、services、部署路径等改成你的环境
2. 若 token 写的是 `${GITEA_TOKEN}`，先 `export GITEA_TOKEN=你的token`
3. docker 要 `docker login` 到你的 Gitea 制品库
4. gitea 的接口自己请求一下看看通不通

### 运行

```bash
easy-deploy
```

就这一条，不要带参数。跑起来后会后台执行，日志在 `logs/deploy-YYYYMMDD-HHMMSS/` 下面。

想卸依赖用 `./uninstall.sh`，会先取消 `easy-deploy` 命令注册，再逐个包问你 y/n，避免误删别的脚本还在用的东西。

## 特别说明

- **运行环境**：Linux + Bash 4+，依赖 curl、jq、yq、unzip、tar、7z、docker、docker compose（V2）
- **并发**：同一时刻只会有一个部署流程在跑（flock 锁）；如果拿不到锁，说明已经有一趟在跑了
- **锁残留**：脚本进程被杀、机器断电之类的情况，可能留下 `data/easy-deploy.lock`，删了这个文件再跑就行
- **版本跳过**：制品版本没变会返回 `skip_deploy`，不会重复部署，也不会 reload nginx
- **详细规格**：见 [prompt/deploy.md](prompt/deploy.md)

## 开源协议

本项目采用 [MIT License](LICENSE) 开源。

Copyright (c) 2026 WIFI连接超时


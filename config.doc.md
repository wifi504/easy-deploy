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
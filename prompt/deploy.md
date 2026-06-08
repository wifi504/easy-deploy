## 整个部署脚本的结构

easy-deploy.sh

easy-deploy-config.yaml

- data/
  - easy-deploy.lock
  - current-versions.json
  - temp/
    - 脚本执行期间的临时文件

- scripts/
  - easy-deploy-agent.sh
  - easy-deploy-worker.sh
  - package-generic.sh
  - package-docker-container.sh
  - deploy-frontend-dist.sh
  - deploy-docker-compose.sh
- logs/
  - deploy-20260102-121233/
    - easy-deploy.sh.log
    - easy-deploy-agent.sh.log
    - easy-deploy-worker.sh.{services对应的name}.log
    - package-generic.sh.{services对应的name}.log
    - package-docker-container.sh.{services对应的name}.log
    - deploy-frontend-dist.sh.{services对应的name}.log
    - deploy-docker-compose.sh.{services对应的name}.log
    - （命名风格就是  执行的shell的文件名+如果会多次执行的脚本的可以用来区分的key+log扩展名）……

## 执行逻辑

### 配置

easy-deploy-config.yaml 是部署脚本的核心配置文件，长相如下

```yaml
# 配置Gitea的访问方式
gitea:
  url: http://10.10.10.11:10088
  token: GITEA_TOKEN

# 日志
logs:
  max-log-history: 10 # logs目录下滚动覆盖，只保留最新的多少次执行的日志，配置为0时，不保留日志，配置为-1时，无上限

# 脚本运行所需的一些配置
scripts:
  # Nginx Reload 命令
  reload-nginx-cmd: "docker exec nginx-webui nginx -s reload"

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

我们的部署脚本的第一版本，`services.package.type` 先只支持 `generic | docker-container` ，`services.deploy.strategy` 先只支持 `frontend-dist | docker-compose`

### 关于日志

每次运行easy-deploy.sh，也就是从入口进去，先在 `./logs/` 创建一个格式为 `deploy-20260102-121233` 的目录，日期时间用UTC+8中国时间，（你也要跟我确认，如何实现前面写的日志保存逻辑，具体存的就是整个执行期间所有shell脚本要打印的所有东西）

### 关于版本

`./data/current-versions.json` 这个文件记录了配置文件里每个 service 现在实际跑着的版本

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

### easy-deploy.sh

easy-deploy.sh 是主入口，可以一次性执行，也可以扔到定时任务里去

这个脚本干两件事：

**Step1. 执行 `easy-deploy-config.yaml` 校验**

为了尽可能防止意外，先做有效性校验

- gitea 能否访问的通，token是否有效

- package的type和deploy的strategy是不是现在版本所支持的

- service的name是不是文件系统允许的文件名（因为日志要引用这个）

- service的name是否存在重复

- 所有的 `deploy.strategy=frontend-dist` 的service的 `deploy.target` 是否存在重复

- 所有的 `deploy.strategy=docker-compose`的service的 `deploy.compose` 是否存在重复

- 所有的 `deploy.target` 是不是一个有效的目录

- 所有的 `deploy.compose` 指向的 `docker-compose.yml` 存在且里面找得到 `deploy.service` 的那个 service

- ……（你要跟我分析探讨一下，还要检查哪些东西，我可能没有列全）

没有通过有效性检查的话，此脚本直接报错退出，然后要把没通过的原因打出来

**Step2. 启动 `easy-deploy-agent.sh`**

若要启动部署流程，必须要先在 `./data` 创建 easy-deploy.lock 文件，内容写入字符串lock，保存，然后锁定这个文件（就是占用这个文件）

如果创建easy-deploy.lock失败（也就是已存在），则脚本直接结束，没有拿到锁，也直接结束

拿到锁，开始执行之后，就可以后台运行 `easy-deploy-agent.sh` 了，也就是说，如果我前台终端手动运行 `easy-deploy.sh`，到这里看到成功开始执行自动化部署字样之后，就退出了

**注意：**

入口这里写的逻辑，是基于我的现有认知，我也不知道Linux有没有专门的机制做这个原子执行，反正，我必须得保证，我无论使用任何手段去同时执行 easy-deploy.sh，最终只有一个 `easy-deploy-agent.sh` 脚本能进入执行，我希望你在plan的时候，能与我确认这里究竟如何实现

### easy-deploy-agent.sh

通过了入口，创建了后台进程，才开始正式走这个脚本的流程，读取 `./easy-deploy-config.yaml` 里的所有 `services` 的 `name`，然后把它作为参数传递给 `easy-deploy-worker.sh` 去后台执行

总的来说，这个脚本会直接把所有 service 分别起个专门处理他们每个人的流程的 worker

等待所有的worker把返回值打回来，无论成功与否，必须得知道他们结束没有

所有worker结束后，释放easy-deploy.lock，并删除这个文件

### easy-deploy-worker.sh

**此脚本执行必要的入参依次：`serviceName`**

读取 `./easy-deploy-config.yaml` 里的 services 的name是入参的那一项

**Step1. 执行 package 逻辑**

如果type是 generic，把 serviceName 传给 `package-generic.sh` 执行，阻塞等待返回值

如果type是 docker-container，把 serviceName 传给 `package-docker-container.sh` 执行，阻塞等待返回值

**Step2. 执行 deploy 逻辑**

首先，Step1得成功，失败的话就不执行了，此脚本报错结束

其次，Step1成功后，判断返回值如果是 `skip_deploy`，此脚本正常结束

如果strategy是 frontend-dist，把 serviceName 和  package 步骤返回值 传给 `deploy-frontend-dist.sh` 执行

如果strategy是 docker-compose，把 serviceName 和  package 步骤返回值 传给 `deploy-docker-compose.sh` 执行

### package-generic.sh

**此脚本执行必要的入参依次：`serviceName`**

读取 `./easy-deploy-config.yaml` 的 service的name等于serviceName的那个配置的package段

**Step1. 找最新**

先找最新的制品version（给你提供curl参考）

```bash
curl -H "Authorization: token ${gitea.token}" \
  "${gitea.url}/api/v1/packages/${package.owner}/generic/${package.owner}/-/latest"
```

这会得到一个 JSON 对象，直接提取 `$.version` 字段，这个就是version

无法获取version，此脚本直接报错结束

如果获取到了version，马上和 `current-versions.json` 里的记录做比对，如果相同，此脚本正常结束，返回 `skip_deploy`

**Step2. 拉最新**

查到版本号且不一样的时候，请求制品文件（给你提供curl参考）

```bash
curl -H "Authorization: token ${gitea.token}" \
  "${gitea.url}/api/packages/${package.owner}/generic/${package.owner}/${前面找到的latest的version}/${package.file}"
```

然后给他存到 temp 目录下，格式为 `./data/temp/随机一个uuid/${package.file}` ，

返回这个存储的绝对路径

### package-docker-container.sh

**此脚本执行必要的入参依次：`serviceName`**

读取 `./easy-deploy-config.yaml` 的 service的name等于serviceName的那个配置的package段

**Step1. 拉最新**

运行pull命令，把远程镜像拉到本地：

```bash
docker pull ${gitea.url去掉前面的http://}/${package.owner}/${package.name}:latest
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

如果成功pull，马上和 `current-versions.json` 里的记录做比对，如果相同，此脚本正常结束，返回 `skip_deploy`

**Step2. 删除旧的**

成功拉取新镜像之后，删除 “除了这个镜像、当前版本记录使用的镜像” 以外的所有版本镜像

返回这个新的Digest

### deploy-frontend-dist.sh

**此脚本执行必要的入参依次：`serviceName`、`tempFile`**

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

把 `current-versions.json` 对应的版本更新

**Step4. Nginx Reload**

运行配置文件里的 `scripts.reload-nginx-cmd`

###　deploy-docker-compose.sh

**此脚本执行必要的入参依次：`serviceName`、`imageDigest`**

读取 `./easy-deploy-config.yaml` 的 service的name等于serviceName的那个配置的deploy段和package段

**Step1. 修改 docker compose 文件**

compose文件的位置是配置文件里 `deploy.compose`

配置文件里 `deploy.service` 就是 compose 文件的 services 里某个 service的名字，用这个去定位那个compose的service块

改compose里 `image` 配置的值：

```
${gitea.url去掉前面的http://}/${package.owner}/${package.name}:@${imageDigest}
```

**Step2. 重启 compose**

先走传统的down掉再up

判断是否成功启动，如果成功启动了，等待 `deploy.started-check-seconds` 秒，判断这个容器在这个期间有没有停止或者重启过，要是停止过，也认为启动失败

**Step3. 重启后状态处理**

如果启动失败了，把compose改回去，然后down掉再up，删除 `入参imageDigest` 对应的镜像，然后此脚本报错退出

如果启动成功了，把 `current-versions.json` 对应的版本更新，删除原来使用的镜像，然后此脚本正常退出

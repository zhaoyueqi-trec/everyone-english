# 1000h-portal CI/CD 学习手册(GitHub Actions + Docker + AWS)

这份手册配套的代码已经写好在这个仓库里了：

```
1000h-portal/Dockerfile                              # 怎么把 Nuxt 应用打包成镜像
.dockerignore                                         # 减小构建体积
1000h-portal/deploy/docker-compose.yml                # 服务器上怎么跑这个镜像
1000h-portal/deploy/.env.example                      # docker-compose 用到的变量示例
.github/workflows/deploy-1000h-portal-docker-aws.yml   # 整条流水线
scripts/aws-server-setup.sh                            # 服务器一次性初始化脚本
```

目标不是让你抄一遍能跑就完事,而是看懂每一步"为什么这么做"。下面按顺序来。

---

## 1. 整体架构

```
你改代码 push 到 GitHub main 分支
        │
        ▼
GitHub Actions 触发 workflow
        │
        ├─ 阶段一 build-and-push
        │    1. checkout 代码
        │    2. 用 Dockerfile 构建镜像
        │    3. 推送镜像到 ghcr.io(GitHub Container Registry)
        │       同时打两个 tag: 1000h-portal-<commit短sha> 和 1000h-portal-latest
        │
        ▼
        └─ 阶段二 deploy(依赖阶段一跑完)
             1. 生成本次部署用的 .env(里面写死这次要用的 sha tag,不用 latest)
             2. 把 docker-compose.yml + .env 用 SCP 传到 AWS 服务器
             3. SSH 登录服务器,执行:
                docker login ghcr.io
                docker compose pull   # 把新镜像拉下来
                docker compose up -d  # 重启容器,用新镜像跑起来
                docker image prune -f # 清理旧镜像,不然磁盘会慢慢被占满
             4. curl 本机检查服务是否正常响应,不正常就打印日志并让整个 job 失败
```

**为什么部署时用 sha tag 而不是 latest?** `latest` 只是个可变的指针,今天指向的镜像和明天指向的可能不是同一个。用 `1000h-portal-<sha>` 这种不可变 tag,你随时能说清楚"服务器上现在跑的到底是哪一次 commit 构建出来的",出问题也方便回滚到某个具体版本(见第 8 节)。`latest` 保留下来只是方便你本地手动 `docker pull` 尝鲜。

**为什么 Nuxt 应用的运行时镜像里没有 node_modules?** Nuxt3 的 Nitro 服务端引擎默认用 `node-server` 预设构建,产物 `.output/server` 是"自包含"的——构建时用到的依赖会被打包进去,运行时镜像只需要 `node .output/server/index.mjs` 就能跑,不需要再装一遍依赖。这也是为什么最终镜像能做得很小。

---

## 2. 前置准备

### 2.1 确认 AWS 服务器状态

你已经有一台装好 Docker 的 EC2 实例。SSH 上去确认一下：

```bash
ssh <你的用户名>@<服务器公网IP>
docker --version
docker compose version   # 注意是 "docker compose"(v2 插件),不是老的 "docker-compose"
```

如果 `docker compose version` 报错说明只有旧版 `docker-compose`,或者压根没装 compose 插件——用仓库里的 `scripts/aws-server-setup.sh` 处理：

```bash
# 本机把脚本传上去
scp scripts/aws-server-setup.sh <用户名>@<服务器IP>:~/

# SSH 上去执行
ssh <用户名>@<服务器IP>
bash aws-server-setup.sh
```

这个脚本是幂等的,反复跑没问题,它会：
- 检查/安装 docker compose 插件、curl
- 把你的用户加进 `docker` 组(这样 GitHub Actions 用这个账号 SSH 上来执行 docker 命令时不需要 sudo)
- 创建 `~/apps/1000h-portal` 目录(部署文件会放这里)
- 给 docker 配置日志轮转,避免容器日志无限增长把磁盘撑爆

**如果脚本提示"加入 docker 组需要重新登录才生效"**,退出 SSH 重新连接一次再继续。

### 2.2 AWS 安全组放行端口

登录 AWS 控制台,找到这台 EC2 实例关联的安全组(Security Group),新增一条入站规则：

| 类型 | 协议 | 端口范围 | 来源 |
|---|---|---|---|
| 自定义 TCP | TCP | 8100 | 学习阶段建议先填你自己的公网 IP(`你的IP/32`),而不是 `0.0.0.0/0` |

`22` 端口(SSH)应该已经开放了,不用动。

> 宿主机端口选了 `8100` 而不是常见的 `3000`,是因为这台服务器上已经跑着 huaxia-qiji(内部用了 3000/8000/5432,虽然目前没绑定到宿主机),用一个不容易撞车的端口,以后再加别的项目也不用每次翻文档确认"3000 到底是谁在用"。容器**内部** Nuxt 还是监听它自己默认的 3000 端口,只是对外映射的宿主机端口换成了 8100,这个改动只影响 `docker-compose.yml` 里的端口映射,不需要改 Nuxt 应用代码。

### 2.3 生成一把"只给部署用"的 SSH 密钥

不要复用你日常登录用的私钥。单独生成一对,公钥加到服务器,私钥放进 GitHub Secrets——这样即使这个私钥泄露,影响面也只是"能部署",而不是"能拿到你完整的服务器权限习惯链"。

```bash
# 在你自己的电脑上执行,生成一对新密钥
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/gh_actions_1000h_portal -N ""

# 把公钥追加到服务器的 authorized_keys
ssh-copy-id -i ~/.ssh/gh_actions_1000h_portal.pub <用户名>@<服务器IP>
# 如果 ssh-copy-id 不可用,手动把 ~/.ssh/gh_actions_1000h_portal.pub 的内容
# 追加到服务器上的 ~/.ssh/authorized_keys 也一样

# 验证新密钥能登录
ssh -i ~/.ssh/gh_actions_1000h_portal <用户名>@<服务器IP> "echo ok"
```

`~/.ssh/gh_actions_1000h_portal`(没有 `.pub` 后缀的那个)就是接下来要放进 GitHub Secrets 的私钥,**原样复制文件内容,包括 `-----BEGIN ... KEY-----` 和 `-----END ... KEY-----` 这两行**。

### 2.4 在 GitHub 仓库配置 Secrets

进入你 fork 的仓库 → `Settings` → `Secrets and variables` → `Actions` → `New repository secret`,依次添加：

| Secret 名 | 值 |
|---|---|
| `AWS_HOST` | 服务器公网 IP 或域名 |
| `AWS_SSH_USER` | SSH 登录用户名(比如 `ubuntu` 或 `ec2-user`) |
| `AWS_SSH_KEY` | 上一步生成的私钥文件**完整内容** |
| `AWS_SSH_PORT` | 可选,SSH 端口,不填默认是 `22` |

`GITHUB_TOKEN` 不用你手动配置,GitHub Actions 每次运行都会自动生成一个,workflow 里直接用 `secrets.GITHUB_TOKEN` 就行——这个 token 既用来把镜像推到 ghcr.io,也会在部署那一步临时传到服务器上做 `docker login`(它是随这次 workflow 运行临时生成、跑完就失效的,不是长期有效的密码,所以不用担心它被服务器"记住"造成长期风险)。

---

## 3. 看懂 Dockerfile

打开 `1000h-portal/Dockerfile`。几个关键点：

1. **为什么构建时用 `--file 1000h-portal/Dockerfile` 但 context 是仓库根目录 `.`?**
   这个仓库是 yarn workspaces 的 monorepo,`1000h-portal` 依赖根目录的 `package.json`、`yarn.lock`、`.yarn` 才能正确装依赖,所以 build context 必须包含整个仓库根目录,Dockerfile 只是放在子目录里而已。

2. **为什么只 `COPY` 各个 workspace 的 `package.json`,不直接 `COPY .` 整个仓库?**
   这是 Docker 分层缓存的经典技巧：只要 `package.json`/`yarn.lock` 没变,`yarn install` 这一层就能复用缓存,不用每次改一行 Vue 代码就重新装一遍依赖,能把 CI 时间从几分钟压缩到几十秒。

3. **为什么用 `yarn workspaces focus 1000h-portal`,而不是直接 `yarn install`?**
   仓库里还有个 `enjoy` workspace(Electron 桌面客户端),它依赖 `sqlite3`、`ffmpeg-static` 这类需要原生编译的包。如果直接在根目录 `yarn install`,会把 `enjoy` 的依赖也一起装了,既慢又容易在容器里编译失败。`workspaces focus` 只安装目标 workspace 真正需要的依赖。
   (`workspaces focus` 依赖 `@yarnpkg/plugin-workspace-tools` 这个功能,一开始我们多写了一行 `yarn plugin import workspace-tools` 手动装它,结果第一次跑 CI 就报错——因为 yarn 4.6.0 已经把这个插件内置了,再手动 import 反而报错退出。这是我们实际踩过的一个坑,已经在 Dockerfile 里去掉了那一行,留着当反面例子:遇到构建报错,先看报错原文,`already installed` 这种字眼往往意味着"这一步根本不需要做"。)

4. **三段式构建(`base` → `deps`/`build` → `runtime`)图的是什么?**
   最终跑在服务器上的镜像只保留 `runtime` 阶段的内容(基础 Node 镜像 + 编译产物),构建过程中用到的 `node_modules`、源码、构建工具全部不会进入最终镜像,镜像体积小很多,攻击面也小。

本地可以先手动验证 Dockerfile 能不能构建成功(可选,不强制,但强烈建议第一次学习时做一遍,排查问题比等 CI 跑完再看日志快得多)：

```bash
cd everyone-english   # 仓库根目录
docker build -f 1000h-portal/Dockerfile -t 1000h-portal:test .
docker run --rm -p 8100:3000 1000h-portal:test
# 另开一个终端
curl http://localhost:8100
```

---

## 4. 看懂 GitHub Actions workflow

打开 `.github/workflows/deploy-1000h-portal-docker-aws.yml`。

- `on.push.paths` 限定了只有 `1000h-portal/**` 目录下的文件变化才会触发这个 workflow——改 `enjoy` 或 `book` 的内容不会误触发部署。
- `on.workflow_dispatch` 让你可以在 GitHub 网页上手动点一个按钮触发,不用非得靠 push 代码才能测试,调试阶段很有用。
- `concurrency` 保证同一时间只有一次部署在跑,新的会自动取消排队中的旧的,避免"两次部署互相抢着改同一个容器"。
- `permissions.packages: write` 是必须的,否则没权限把镜像推到 ghcr.io。
- `build-and-push` job 用 `docker/build-push-action` 构建并推送,`cache-from/cache-to: type=gha` 是让 Docker 的构建缓存存在 GitHub Actions 自己的缓存里,下次构建能复用,加快速度。
- `deploy` job 通过 `needs: build-and-push` 声明依赖关系,保证一定是"镜像先推送成功,再去部署",两个 job 之间还通过 `outputs` 把镜像名和 tag 传递过去。
- 部署用了两个第三方 action：`appleboy/scp-action`(传文件)和 `appleboy/ssh-action`(远程执行命令),这是社区里做"SSH 部署"最常用的两个 action。

---

## 5. 第一次手动触发部署

1. 把这些新增文件提交并推到你 fork 的仓库(GitHub 网页操作或本地 `git push` 都行)。
2. 打开 GitHub 仓库页面 → `Actions` 标签 → 左侧找到 `Deploy 1000h-portal (Docker to AWS)`。
3. 点右侧 `Run workflow` 按钮,选择 `main` 分支,手动触发一次。
4. 点进这次运行,展开 `build-and-push` 和 `deploy` 两个 job 的日志,跟着看每一步。
5. 跑完之后,在你自己电脑上验证：
   ```bash
   curl http://<服务器公网IP>:8100
   ```
   或者浏览器直接打开 `http://<服务器公网IP>:8100`。

---

## 6. 日常开发流程演练

这是你以后真实会重复做的事,建议明天也practice 一遍：

1. 改一点 `1000h-portal` 里的内容(比如改一行首页文案)。
2. `git add` / `git commit` / `git push` 到 `main` 分支(或者走 PR 合并到 main,取决于你的分支策略)。
3. 因为 workflow 里配置了 `paths: 1000h-portal/**`,这次 push 会自动触发部署,不需要手动点按钮。
4. 去 Actions 页面看它自动跑完。
5. 刷新服务器地址,确认改动生效。

---

## 7. 常见故障排查

| 现象 | 大概率原因 | 排查方法 |
|---|---|---|
| `build-and-push` 阶段失败,`yarn install`/构建报错 | 依赖装不上,或代码本身编译报错 | 先在本地按第 3 节的方法手动 `docker build` 一遍复现 |
| `scp-action`/`ssh-action` 报连接失败 | Secrets 配错了,或安全组没开 22 端口,或私钥格式不对 | 用本机 `ssh -i <私钥文件> <用户>@<IP>` 手动连一次,确认没问题再检查 Secrets 是不是完整复制(包含 BEGIN/END 行) |
| SSH 能连,但 `docker` 命令报 `permission denied` | 部署用的用户不在 docker 组 | 重新执行 `scripts/aws-server-setup.sh`,然后**必须重新 SSH 登录一次**权限才生效 |
| `docker compose pull` 报 `unauthorized`/`denied` | `docker login ghcr.io` 没成功,或者镜像包(package)权限有问题 | 去 GitHub 仓库页面 → 右侧 `Packages` 里检查这个包的可见性/权限设置 |
| 健康检查 `curl` 失败,workflow 在最后一步报错 | 容器起来了但应用没监听成功,或者监听的端口/HOST 不对 | 日志里已经打印了 `docker compose logs --tail=100`,直接看容器内部报了什么错;也可以 SSH 上去手动 `docker compose logs -f` 实时看 |
| 浏览器打不开,但服务器上 `curl localhost:8100` 是通的 | 安全组没放行,或者你输入的是内网 IP | 检查第 2.2 节的安全组规则,确认用的是公网 IP |

---

## 8. 回滚

因为每次部署都会打一个不可变的 `1000h-portal-<sha>` tag,回滚不需要重新跑 CI,直接手动改服务器上跑的 tag 就行：

```bash
ssh <用户名>@<服务器IP>
cd ~/apps/1000h-portal

# 查一下 ghcr.io 上有哪些历史 tag,或者看 GitHub 仓库 -> Packages 页面
# 手动把 .env 里的 IMAGE 改成想回滚到的那个 sha tag
vim .env
# 例如: IMAGE=ghcr.io/xxx/everyone-english:1000h-portal-abc1234

docker compose pull
docker compose up -d
```

---

## 9. 学明白之后可以自己练的进阶方向

- **加一层 Nginx 反向代理 + HTTPS**:现在是直接把宿主机 8100 端口(映射到容器内部的 3000)暴露给公网,生产环境更常见的做法是用 Nginx(或 Caddy)做反向代理,配 Let's Encrypt 证书,只对外暴露 443,这台机器上 huaxia-qiji 的 nginx 已经占了 80/443,以后要给 1000h-portal 也配反代和域名,需要在 nginx 配置里按域名/路径分流到不同后端,而不是两个项目抢同一个 443。
- **多环境(staging / production)**:复制一份 workflow,加一个 staging 分支触发部署到另一台测试服务器,验证没问题再手动 approve 部署到生产。GitHub Actions 的 `environment` + 保护规则(需要人工审批)可以练一下。
- **零停机 / 蓝绿部署**:现在 `docker compose up -d` 重启容器的瞬间会有几秒钟服务不可用,可以研究一下怎么先起新容器、健康检查通过后再切流量、最后再关旧容器。
- **告警**:部署失败时通过钉钉机器人/Slack/邮件通知自己,而不是要主动去 Actions 页面看。
- **把 `enjoy` 的桌面应用打包(`build-enjoy-app-*.yml`)和这条 Docker+AWS 流水线对比着看**,同一个仓库里两种完全不同的 CI/CD 目标(发布桌面安装包 vs 部署长期运行的服务),能帮助理解"CI/CD 具体要做什么"取决于你的部署目标是什么形态的产物。

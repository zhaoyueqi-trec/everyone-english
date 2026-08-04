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

只加上面这四个还不够——第一次实际跑通整条流水线时会在 SCP 那一步卡住报错,原因和解决办法见下一节。

### 2.5 让 GitHub Actions 能连上服务器的 22 端口(动态 IP 白名单)

之前把 SSH 22 端口锁定成"只允许自己当前的公网 IP",是为了防止扫描/暴力破解。但 GitHub Actions 部署时,真正发起 SSH 连接的是 **GitHub 云端的 runner**,它的出口 IP 是每次运行随机分配的,根本不在你的白名单里——第一次实际跑这条流水线时就踩到了这个坑,报错是：

```
error copy file to dest: ***, error message: dial tcp ***:22: i/o timeout
```

解决办法:workflow 里新增两步——部署前先查出这次 runner 的公网 IP,临时追加进 Lightsail 防火墙的 22 端口白名单(不影响你原来那两条固定 IP 的规则,只是多加一条);部署结束后不管成功还是失败,最后都会把这条临时规则撤销,恢复到部署前的状态。整个过程全自动,不需要你每次手动去控制台加/删 IP。

这需要让 GitHub Actions 有权限调用 AWS API 去改防火墙规则,所以要专门建一个权限收得很窄的 IAM 用户,只干这一件事。

#### 2.5.1 创建 IAM 权限策略

AWS 控制台 → **IAM** → **Policies** → **Create policy** → 切到 **JSON** 标签,贴入：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lightsail:GetInstancePortStates",
        "lightsail:PutInstancePublicPorts"
      ],
      "Resource": "*"
    }
  ]
}
```

> 这个策略只允许"查看/修改端口开放状态"这一件事,没有创建/删除实例、没有读数据、没有任何别的权限。`Resource: "*"` 图省事覆盖了这个账号下所有 Lightsail 实例,更严谨的做法是把 `Resource` 收紧成只对这一台实例的 ARN 生效(格式 `arn:aws:lightsail:<region>:<account-id>:Instance/<instance-name>`),可以作为后续练习自己收紧,不影响现在先跑通。

起个名字,比如 `1000h-portal-github-actions-firewall`,创建。

#### 2.5.2 创建 IAM 用户,绑定这个策略

AWS 控制台 → **IAM** → **Users** → **Create user**：
- User name:比如 `github-actions-1000h-portal`
- **不要**勾选 "Provide user access to the AWS Management Console"——这个用户只给程序调 API 用,不需要能登录网页控制台
- 权限这一步选 **Attach policies directly**,勾选刚才创建的 `1000h-portal-github-actions-firewall`
- 创建完成

#### 2.5.3 生成访问密钥

进这个新用户的详情页 → **Security credentials** 标签 → **Access keys** 区块 → **Create access key**：
- Use case 选跟"第三方程序 / AWS 外部的应用访问"最接近的那个选项(不同界面版本文案略有差异)
- 创建完成后会显示一次性的 **Access key ID** 和 **Secret access key**——**这是唯一一次能看到 Secret access key 的机会,页面关掉就再也看不到了**,先别关,接着做下一步。

#### 2.5.4 添加到 GitHub Secrets

**这两个值不要粘贴到咱们的对话里**,直接在你自己电脑的终端操作(这台电脑的 `gh` 命令行工具已经登录好了)：

```bash
gh secret set AWS_ACCESS_KEY_ID --repo zhaoyueqi-trec/everyone-english
# 会提示你输入值,把 Access key ID 粘贴进去回车

gh secret set AWS_SECRET_ACCESS_KEY --repo zhaoyueqi-trec/everyone-english
# 同样,把 Secret access key 粘贴进去回车
```

或者走网页 `Settings → Secrets and variables → Actions → New repository secret`,跟之前加 `AWS_HOST` 那几个操作一样,只是这次多加这两个：

| Secret 名 | 值 |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM 用户的 Access key ID |
| `AWS_SECRET_ACCESS_KEY` | IAM 用户的 Secret access key |

加完之后,回到还开着的 AWS 控制台页面,点 **Done** 关掉就行(密钥已经不需要再对着网页抄一遍了)。

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
- `deploy` job 最开始的"配置 AWS 凭证" + "临时把本次 runner 的公网 IP 加入 22 端口白名单"这两步,对应第 2.5 节讲的问题:GitHub Actions 的出口 IP 不固定,得在部署前先临时开白名单。这一步用 `aws lightsail get-instance-port-states` 读出当前完整的防火墙规则存成快照,再用 `jq` 只给 22 端口那一条追加这次 runner 的 IP,其余规则原样不动,最后 `aws lightsail put-instance-public-ports` 写回去——`put` 这个 API 是整体覆盖式的(不是"追加一条"），所以必须先读全量、改一小块、再整体写回,不能只传一条新规则上去,不然会把其他规则全部冲掉。
- 最后一步"撤销临时白名单,恢复防火墙原状"用了 `if: always()`,意思是不管前面哪一步失败,这一步都会执行——保证不会因为部署中途报错就永久留下一个对外网开放的 22 端口漏洞。

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
| 报错 `dial tcp ***:22: i/o timeout` | 22 端口白名单没放行 GitHub Actions runner 这次的出口 IP | 确认第 2.5 节的 `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` 加了没有,以及 IAM 用户权限、`LIGHTSAIL_INSTANCE_NAME` 是否和实际实例名一致;也可以去日志里看"临时把本次 runner 的公网 IP 加入 22 端口白名单"这一步有没有报错 |
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

## 8.5 最终访问地址:和 huaxia-qiji 共用一个域名、按路径分流

8100 那个端口一开始是为了绕开"公司网络不让访问非常规端口"这个问题,但更彻底的解法是接到已有的 HTTPS 域名上,所以最终线上正式地址是：

```
https://5ways.duckdns.org/every1english/
```

`5ways.duckdns.org` 是专门给"huaxia-qiji 之外的其它小项目"用的统一入口,不是 1000h-portal 独占的域名——以后再加新服务,只需要在服务器的 `~/huaxia-qiji/nginx.conf` 里新增一个 `location` 路径块,不需要再注册新域名、再申请新证书。8100 端口现在仍然保留着(方便本机/服务器内部直接测试),但对外应该用上面这个域名访问。

这一步涉及到的改动都不在这个仓库里能看到(nginx 是 huaxia-qiji 那台服务器上的公共基础设施,配置文件在服务器上,不在 `everyone-english` 这个仓库的版本控制范围内),记录一下方便以后排查：

- 服务器上 `~/huaxia-qiji/nginx.conf` 新增了 `5ways.duckdns.org` 的 80跳转 + 443 SSL 两个 `server` 块,`xue5ya.duckdns.org` 原有的配置块完全没动。
- 证书是用 **DNS 验证**(不是 huaxia-qiji 当初用的 standalone 方式)申请的,好处是申请/续期全程不需要占用 80 端口、不需要停 nginx。对应的钩子脚本在服务器的 `~/duckdns/certbot-auth-hook.sh` / `certbot-cleanup-hook.sh`,复用了 `~/duckdns/duck.sh` 里已有的 DuckDNS token。
- `1000h-portal` 容器接入了 huaxia-qiji 的 Docker 网络(`huaxia-qiji_huaxia_network_dev`),这样 nginx 才能直接用容器名 `1000h-portal` 访问到它——这层网络关系写在了本仓库 `1000h-portal/deploy/docker-compose.yml` 的 `networks` 配置里(见下面"踩过的坑"第一条,为什么必须写在这里而不是手动 `docker network connect` 一次就完事)。

### 踩过的两个坑(真实发生过,留着当反面教材)

| 现象 | 根因 | 修法 |
|---|---|---|
| 手动 `docker network connect` 接好网络后,下一次自动部署(push 触发 CI/CD)一跑,nginx 疯狂重启,日志报 `host not found in upstream "1000h-portal"` | `docker compose up -d` 重建容器时,只认容器自己 compose 文件里声明的网络,不知道有一条手动加的网络关系,重建的新容器就把这层连接丢了 | 把这层网络关系**写进 `1000h-portal/deploy/docker-compose.yml` 的 `networks` 里**(声明成 `external: true` 指向 huaxia-qiji 那个真实网络名),让它成为每次部署都会被应用的"永久配置",而不是一次性的手动操作 |
| nginx 配置改成按路径转发之后,访问 `/every1english/` 应用返回的是 Nuxt 自己的 404 页面(不是 nginx 层面的错误) | Nuxt 配了 `app.baseURL: '/every1english/'` 之后,应用**期望收到的请求路径里带着这个前缀**去做内部路由匹配;但 nginx 的 `proxy_pass http://1000h-portal:3000/;`(结尾带斜杠)会把这个前缀转发前**剥掉**,导致应用收到的是不带前缀的路径,匹配不到任何路由 | 把 `proxy_pass` 结尾的 `/` 去掉,变成 `proxy_pass http://1000h-portal:3000;`(不带斜杠),nginx 就会把请求原始路径(含 `/every1english/` 前缀)原样转发给应用,交给应用自己按 `baseURL` 内部处理 |

这两个坑本质上是同一类问题的两种表现:**"手动在服务器上改了一下、看着好使了"和"这个改动能不能扛住下一次自动化部署/配置变更"是两回事**,验证的时候一定要连着"再触发一次真实的自动部署"一起测,不能改完手动测一次就当结束了。

---

## 9. 学明白之后可以自己练的进阶方向

- ~~加一层 Nginx 反向代理 + HTTPS~~ **已完成**,见第 8.5 节:复用 huaxia-qiji 现有的 nginx,新增了 `5ways.duckdns.org` 这个域名按路径分流,`1000h-portal` 落在 `/every1english/` 这个路径下,证书用 DNS 验证申请、不占 80 端口。以后再加新服务,照着同样的模式在 nginx 里加一个新 `location` 路径就行,不用再申请新域名/新证书——这个"一个域名多路径"的模式已经是这台服务器上的既定架构,可以直接复用。
- **多环境(staging / production)**:复制一份 workflow,加一个 staging 分支触发部署到另一台测试服务器,验证没问题再手动 approve 部署到生产。GitHub Actions 的 `environment` + 保护规则(需要人工审批)可以练一下。
- **零停机 / 蓝绿部署**:现在 `docker compose up -d` 重启容器的瞬间会有几秒钟服务不可用,可以研究一下怎么先起新容器、健康检查通过后再切流量、最后再关旧容器。
- **告警**:部署失败时通过钉钉机器人/Slack/邮件通知自己,而不是要主动去 Actions 页面看。
- **把 `enjoy` 的桌面应用打包(`build-enjoy-app-*.yml`)和这条 Docker+AWS 流水线对比着看**,同一个仓库里两种完全不同的 CI/CD 目标(发布桌面安装包 vs 部署长期运行的服务),能帮助理解"CI/CD 具体要做什么"取决于你的部署目标是什么形态的产物。

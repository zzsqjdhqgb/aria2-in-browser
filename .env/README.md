# DSH 容器开发环境

把 DSH（DeepSeek Harness）和这个项目跑在同一个容器里，绕开桌面端在 Windows 上的沙箱问题。

组成就三样：**一个工具镜像 + 一层只负责「端口映射 / 挂载卷 / 环境变量」的 docker-compose + 几个一行的 bat**。compose 里**不写 `command:`**，容器永远以镜像默认的 `bash` 启动；真正的启动命令由 bat 在 `docker compose run ... dev <命令>` 里传进去（例如执行 `sh/` 下的脚本）。

**镜像只提供工具和 DSH 环境，不碰项目**：不拷任何项目文件进镜像，构建时也不执行任何项目命令（没有 `yarn install`、没有 postinstall、没有 `wxt prepare`）。项目通过挂载进容器，依赖要你自己在容器里装。（镜像确实会预装 AgentTeams 插件，但那是装进 DSH 的 profile，跟项目无关 —— 见下面「镜像自带 AgentTeams 插件」。）

## 文件说明

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 工具镜像：Node 24 + dsh CLI + git/ripgrep/python3 + pnpm + yarn4 + socat，**以 root 运行**，`CMD ["bash"]` |
| `docker-compose.yml` | **只管端口映射、卷挂载、env_file**，单服务 `dev`，无 `command`；并把 `.git` 以**只读**挂进容器 |
| `docker-build.bat` | `docker compose ... build`，构建镜像 `dsh-dev:local` |
| `docker-bash.bat` | `docker compose ... run --rm dev bash`，前台 bash 容器 |
| `docker-dsh.bat` | 同上再加 `--service-ports`，启动 `sh/dsh.sh`（socat + dsh web），宿主访问 `http://localhost:3080` |
| `docker-attach.bat` | 连进**唯一**在运行的容器；0 个或多个都报错退出 |
| `sh/dsh.sh` | 容器内启动脚本（socat + dsh web）。其他启动方式照此新增 |
| `.env` / `env.example` | 变量文件，供 compose 插值与注入 |
| `.gitignore` | 忽略宿主侧 `.env/.env` |

镜像的 `ENTRYPOINT` 与插件 provision 脚本（`dsh-entrypoint.sh`、`dsh-profile-provision.sh`）**不存在于本目录**：它们由 `Dockerfile` 用自己的 heredoc 直接写进 `/usr/local/bin/`，`Dockerfile` 是唯一真相。

仓库根目录另有一份 `.dockerignore`（只用于缩小构建上下文）。

## 编码与换行约定

- `Dockerfile`、`*.bat`、`docker-compose.yml`、`.env`、`env.example` 一律**纯 ASCII**。bat 由 cmd.exe 按控制台代码页读取，UTF-8 中文会变乱码并可能破坏解析；`.env` 由 compose 读取，也保持 ASCII 最稳。
- `*.bat` 用 **CRLF**；`sh/*.sh` 用 **LF**（bash 遇到行尾的 `\r` 会报 `command not found`）。
- 本 `README.md` 是唯一例外：给人看的文档，中文无妨。

## 快速开始

Docker Desktop 需要处于运行状态。在**仓库根目录**的 cmd 里执行（bat 也能直接双击）：

```bat
rem 1) 构建镜像（首次拉取 node:24-bookworm-slim 并装 dsh / pnpm / yarn，需要几分钟）
.env\docker-build.bat

rem 2) 进容器（前台 bash；退出即销毁容器，两个数据卷保留）
.env\docker-bash.bat
```

`.env\.env` 已存在并有默认值，需要时直接改它（`DSH_WEB_PORT`、`TZ`、API key）。想恢复默认就从 `env.example` 复制一份。

进入容器后，**第一次要先装依赖**（镜像里没有）：

```bash
dsh --version          # 应输出版本号
yarn install           # 首次必做；结果落在 dsh-node-modules 卷里，不写宿主
yarn test              # 跑项目测试
yarn dev               # 启动 wxt 开发模式
```

`yarn install` 会按项目 `package.json` 里锁定的 `packageManager: yarn@4.17.1` 自动取用对应 yarn，并触发项目自己的 postinstall（`wxt prepare`）——这些都是你主动在容器里执行的结果，不是镜像构建时跑掉的。

## 镜像自带 AgentTeams 插件（关键机制）

镜像自带 [`@nanmicoder/dsh-agent-teams`](https://www.npmjs.com/package/@nanmicoder/dsh-agent-teams)（多智能体团队插件：captain + 成员 + 共享任务 DAG + Web 团队面板）。版本与 dsh 版本都只写在 `Dockerfile` 顶部：

```dockerfile
ARG DSH_VERSION=0.2.0-rc.2
ARG AGENT_TEAMS_VERSION=0.1.22
```

### 为什么不能在构建时装进 `/root/.dsh`

`/root/.dsh` 是卷 `dsh-dev_dsh-home`。**卷只在第一次创建时从镜像复制内容，之后会把镜像里同一路径完全遮住**。所以 `docker build` 期间往 `/root/.dsh` 装插件，任何容器都看不到；重建镜像也永远更新不了已存在的卷。DSH 解析插件只有两个锚点（安装目录 + profile 目录），没有第三个可配置的插件位置，所以绕不过这件事。

### 实际做法：构建只预热，安装发生在容器启动后

1. **构建**：把 `DSH_HOME` 重定向到 `/opt/dsh-plugin`，跑一次官方命令 `dsh plugin --profile web add --save-exact @nanmicoder/dsh-agent-teams@<版本>`，然后**把这个临时 profile 删掉**。留下的只有两样东西：`/opt/dsh-plugin/cordis.patch.yml`（镜像的插件配置）和 `/root/.local/share/pnpm/store` 里被预热的 tarball（在镜像内，不在任何卷上）。
2. **启动**：容器的 `ENTRYPOINT` → provision 脚本，在**卷已挂载之后**对 `$DSH_HOME` 跑同一个官方命令。所以结果和你在容器里手敲一遍完全一样，并且**留在卷里**；之后才 `exec "$@"` 执行原命令（`bash`、`sh/dsh.sh` 都不受影响）。

> 这两个脚本**由 `Dockerfile` 用自己的 heredoc 写进镜像**，不是 `COPY` 进上下文的：构建上下文是整个仓库、而 `.env/` 是其中的点目录，在 Windows 主机上曾出现上下文遍历没把 `.env/sh/` 下新增文件交给 BuildKit（`COPY` 报 `sh/... : not found`）。改成内嵌后，镜像不再依赖"上下文里有没有这些文件"，`Dockerfile` 是这两个脚本的唯一真相。要单独测试它们，从 `Dockerfile` 里提取（`cat > /usr/local/bin/<名字> <<'SH'` 到单独的 `SH` 行之间就是脚本全文）。

行为细节：

- **重复启动零成本**：先比对卷里已装版本与 `DSH_PLUGIN_VERSION`，相同就打印一行 `already installed` 直接跳过（实测 0.02 秒、不写盘、不联网）。
- **离线优先**：需要安装时先试 `--offline`（用镜像预热的 store，实测约 1 秒、无 registry 流量），打不中才回退联网。
- **装不上也能启动**：安装失败只警告，容器照常起来 —— 卷里有旧版就用旧版，没有就不挂插件。DSH 自己的兼容闸门（插件 peer 与 dsh 版本不匹配）也会在这条路径上拦截，实测会保留卷里已有的版本。
- **补丁层按内容挂载**：`cordis.patch.yml` 与镜像那份不同才覆盖，所以改 Dockerfile 里的配置、重建镜像后，下次启动生效。
- **不碰别的**：凭据、`settings.yaml`、会话记录都在卷里，脚本只写 `profiles/<name>/` 下的插件与 `cordis.patch.yml`。

### 相关环境变量（镜像里已设默认值）

| 变量 | 默认 | 作用 |
|---|---|---|
| `DSH_PLUGIN_VERSION` | 由 `ARG AGENT_TEAMS_VERSION` 生成 | 要装的插件版本，也是幂等判断依据 |
| `DSH_PLUGIN_PACKAGE` | `@nanmicoder/dsh-agent-teams` | 要装的包名 |
| `DSH_PLUGIN_PATCH` | `/opt/dsh-plugin/cordis.patch.yml` | 要挂进 profile 的补丁层 |
| `DSH_SEED_PROFILES` | `web` | 要 provision 的 profile |
| `DSH_PLUGIN_REFRESH` | 空 | 设 `1` 强制重装（即使版本相同） |
| `DSH_PLUGIN_TIMEOUT` | `600` | 单次安装的超时秒数 |

### 镜像里给插件写了什么默认值

`cordis.patch.yml` 由 `Dockerfile` 的 heredoc 生成（**改它要改 Dockerfile，不要在容器里改——容器里改的会在下次启动被覆盖**）：

- `maxMembers: 16` —— 花名册上限，插件默认 8。一个交付通常就要「实现者 + 验证者 + 审查者」，8 会卡住并行；空闲成员不发模型请求，所以上限本身不花 token。
- `profiles:` 两个开箱即用的团队模板，任何会话都能用 `/agent-teams --profile <名字> <目标>` 直接起：
  - `feature-delivery`：analyst → implementer →（verifier ∥ reviewer），需求→实现→验证→审查
  - `audit`：code-reader ∥ history-reader ∥ risk-reader，同一问题的三个独立视角
  - 成员只写 `role`、不锁 `provider`/`model`，因此继承 captain 当前模型路由。

### 怎么改

| 想做的事 | 改哪里 |
|---|---|
| 升级插件版本 | 改 `Dockerfile` 的 `ARG AGENT_TEAMS_VERSION`，重建镜像；下次启动自动装新版（旧版还在时先试离线，装不上就继续用旧版） |
| 改插件配置 / 团队模板 | 改 `Dockerfile` 里 heredoc 那段，重建镜像；下次启动按内容差异覆盖 |
| 只想在这一次容器里加插件 | 容器里直接 `dsh plugin --profile web add ...`，留在卷里，重启仍在（不受本机制影响） |
| 怀疑状态不对 | `DSH_PLUGIN_REFRESH=1 docker compose ... run --rm dev bash` 强制重装 |

验证（构建后、或进容器后）：

```bash
dsh --profile web --dump-config | grep -A 6 "id: agent-teams"   # 应看到 maxMembers: 16 和两个 profiles
ls -l /root/.dsh/profiles/web/node_modules/@nanmicoder/          # 插件应已装进卷
```

`--dump-config` 只能证明配置**组合结果**；`maxMembers` 在运行期解析进内存、没有对外读取接口，除非真去建一个超过上限的花名册，否则看不到它被触发的报错。

## compose 负责什么

`docker-compose.yml` 只有一个服务 `dev`，里面**没有 `command:`**，只有三类东西：

```yaml
services:
  dev:
    build: { context: .., dockerfile: .env/Dockerfile }
    image: dsh-dev:local
    env_file: [.env]                                   # 环境变量
    ports: ["${DSH_WEB_PORT:-3080}:3080"]              # 端口映射
    volumes:                                           # 卷挂载
      - ..:/workspace
      - ../.git:/workspace/.git:ro                     # git 目录：只读
      - dsh-node-modules:/workspace/node_modules
      - dsh-home:/root/.dsh
    extra_hosts: ["host.docker.internal:host-gateway"]
```

因此 bat 里不再出现任何 `-p` / `-v` / `-e`，只保留三件事：compose 文件位置、`--env-file`、以及要跑的命令。

> `--env-file` 只影响 `${...}` 插值；变量真正进容器靠服务上的 `env_file: .env`。两者都指向同一个文件。

## 容器内的 .git 是只读的

`.git` 用 `../.git:/workspace/.git:ro` 单独覆盖挂载（嵌套挂载会盖住上面的 `..:/workspace`，机制和下面的 `node_modules` 卷一样），于是：

| 命令 | 容器内 | 说明 |
|---|---|---|
| `git status` / `git log` / `git diff` / `git show` | 可用 | 只读查看，随便用 |
| `git commit` / `git add` / `git branch` / `git checkout` / `git stash` | 失败 | 写 `.git` 被拒绝，**提交一律在宿主做** |

配套两个设置，都已固化进镜像的 `Dockerfile`：

- `GIT_OPTIONAL_LOCKS=0`：告诉 git 不要为了刷新 stat cache 去写 `.git/index`。没有它，`git status` 一般也能跑（git 会静默容忍写失败），但那是碰运气，加上才是确定的。
- `git config --system --add safe.directory /workspace`：**兜底项**。容器现在跑 root、挂载也是 root 属主，这项检查本来就能过；留着是为了挂载带别的 uid 时（Linux 宿主，或 Docker Desktop 的非 root 映射）git 不会直接 `fatal: detected dubious ownership` 罢工。写在 `/etc/gitconfig`（镜像层）才能跨容器存活——写 `~/.gitconfig` 不行，`/root` 本身不是卷。

想临时让容器内也能提交：把 `docker-compose.yml` 里 `../.git:/workspace/.git:ro` 那一行注释掉，重新起容器即可。

## 四个 bat 的细节

### docker-build.bat

```bat
docker compose --env-file "%~dp0.env" -f "%~dp0docker-compose.yml" build
```

`%~dp0` 是 bat 所在目录（`.env\`），所以 compose 的 `context: ..` 解析到仓库根目录，`.dockerignore` 生效。

改 dsh 版本：改 `Dockerfile` 顶部的 `ARG DSH_VERSION=<版本>`（唯一指定处）。插件版本在它下面的 `ARG AGENT_TEAMS_VERSION`，两者要满足插件的兼容矩阵。`.env`、`env.example`、`docker-compose.yml` 都没有版本号，也不是 build arg。

### docker-bash.bat / docker-dsh.bat

区别只有一个 `--service-ports` 和镜像名后面那条命令：

```bat
rem bash：默认交互式 shell，不发布端口
docker compose run --rm dev bash

rem dsh：--service-ports 才会发布 compose 里写的 3080；再执行容器内的 sh/dsh.sh
docker compose run --rm --service-ports dev bash /workspace/.env/sh/dsh.sh
```

`run --rm` 是前台运行、结束即删：**没有常驻容器，没有 restart 策略**。真正留下来的只有：

| 会留下 | 内容 | 怎么删 |
|---|---|---|
| 卷 `dsh-dev_dsh-home` | 登录凭据、`settings.yaml`、会话记录，以及 profile（含装好的 AgentTeams 插件，所以重启不必重装；镜像换了插件版本才需要再装一次） | `docker volume rm dsh-dev_dsh-home` |
| 卷 `dsh-dev_dsh-node-modules` | 容器里 `yarn install` 装出的依赖 | `docker volume rm dsh-dev_dsh-node-modules` |
| 镜像 `dsh-dev:local` | 构建产物 | `docker image rm dsh-dev:local` |

卷名带 `dsh-dev` 前缀来自 compose 的 `name: dsh-dev`；更早版本（旧 compose 项目名 `aria2-browser-shim-dsh`）留下的卷不再使用，可自行 `docker volume rm`。

### 自定义启动命令

容器默认 `bash`，所以「容器里要跑的东西」直接追加在服务名后面，不用改 Dockerfile：

```bat
docker compose run --rm dev dsh --version
docker compose run --rm dev bash -lc "yarn test"
```

需要多步启动（先起 A 再起 B）的，写成一个 sh 放进 `sh/`，再 `... run dev bash /workspace/.env/sh/<名字>.sh`。`docker-dsh.bat` 就是这么做的。

## Web UI 从宿主访问

**这是最容易踩的坑**：`dsh web` 只绑回环地址，容器外访问不到，浏览器会报 `ERR_EMPTY_RESPONSE`。

依据：`dsh web` 的 `--host` **明确拒绝 `0.0.0.0`**（usage error），但服务端本身支持绑全网卡。所以：

- compose 端口映射 `${DSH_WEB_PORT:-3080}:3080`（宿主 3080 → 容器 3080），由 `--service-ports` 发布
- `sh/dsh.sh` 里 `socat` 监听容器 `0.0.0.0:3080`，转发到 `127.0.0.1:3081`
- 真正的服务是 `dsh web --port 3081`

浏览器访问 `http://localhost:3080`。额外好处：浏览器看到的 Host 就是 `localhost:3080`，本来就在回环白名单里，带 token 的启动 URL 和签名 cookie 握手都不用改。

打不开时按顺序排查：

1. 容器内服务是否活着：`docker-attach.bat` 进去后 `curl -sv http://127.0.0.1:3081/ -o /dev/null`
2. relay 是否在听：同 shell 里 `curl -sv http://127.0.0.1:3080/`
3. 换 IP 字面量试：用 `http://127.0.0.1:3080` 而不是 `localhost`（被 Host 白名单拒绝的只有「名字」，IP 字面量放行）

## attach：连进已开着的容器

`docker-bash.bat` / `docker-dsh.bat` 是**新建**容器；`docker-attach.bat` 相反，它用 `docker exec` 连进**已经在运行**的容器，不新建。

```bat
rem 终端 1：把 Web UI 跑起来（前台运行，窗口被占住），保持它开着
.env\docker-dsh.bat

rem 终端 2：钻进同一个容器里看文件、跑命令
.env\docker-attach.bat
```

行为：

- 按镜像 `dsh-dev:local` 定位容器（`docker ps --filter ancestor=...`），不管是 compose `run` 还是 `up -d` 起的都能找到，也不会误连别的项目。
- **一个都没在跑** → 报错退出，并提示用 bash / dsh 启动。
- **同时在跑多个** → 直接报错退出并列出 ID/名字，让你自己挑（不做「按序号选」，避免 bat 里的数组/动态变量坑）。
- 退出这个 shell 只是断开连接，**容器继续运行**。

## 模型凭据

两条路，任选：

**A. 容器内配置（推荐）** — 凭据写进 `$DSH_HOME` 卷里的 `.credentials.yaml`，删容器不影响：

```bash
dsh web        # 或按 profile 的配置向导走
```

**B. 环境变量** — 编辑 `.env\.env`，取消对应行注释并填 key，下次启动容器即生效（`env_file` 注入，不用重建镜像）：

```
DEEPSEEK_API_KEY=sk-...
SILICONFLOW_API_KEY=sk-...
OPENAI_API_KEY=sk-...
```

`dsh` 的 home 解析顺序为：显式配置 > `$DSH_HOME` > `~/.dsh`。本环境显式把 `DSH_HOME` 设为 `/root/.dsh`，并挂到 `dsh-home` 卷。

## 目录与卷的对应关系

| 宿主 | 容器 | 说明 |
|---|---|---|
| 仓库根目录 | `/workspace` | bind mount，宿主改代码容器立刻可见（不是卷） |
| 仓库根目录的 `.git` | `/workspace/.git` | **只读** bind mount，覆盖在上一条之上：可读历史与 diff，不能提交、切分支、改索引 |
| 卷 `dsh-dev_dsh-node-modules` | `/workspace/node_modules` | 隔离宿主 `node_modules`：容器里 `yarn install` 的结果落在这里，不往 Windows 写 1.5 万个小文件 |
| 卷 `dsh-dev_dsh-home` | `/root/.dsh` | 登录凭据、`settings.yaml`、profile、装好的插件（entrypoint 在启动时把镜像指定的插件版本 provision 进来） |

容器内以 **root**（uid 0）运行：Dockerfile 里没有 `USER`，`HOME` 和 `DSH_HOME` 都在 `/root` 下。因此 yarn 的全局缓存是 `/root/.yarn/global`，而不是宿主项目里的 `.yarn/`。在 Linux 宿主上，容器里新建的文件属主会是 root；Windows/Docker Desktop 的 bind mount 不跟踪属主，看不出差别。

## 访问宿主上的服务

容器内用 `host.docker.internal`（compose 已加 `host-gateway`）。例如宿主跑着 aria2 RPC：

```
http://host.docker.internal:6800/jsonrpc
```

## 已知不确定项（未在本机验证过）

1. **容器内 `yarn install`**：yarn 4 由 Corepack 按项目的 `packageManager` 字段提供，首次执行时会下载对应版本。若报 `packageManager` 相关错误，改用 `corepack yarn install`；要彻底绕开 Corepack，可 `corepack disable` 后 `npm i -g yarn@4.17.1`。
2. **`docker compose run` 的交互性**：服务已声明 `stdin_open` / `tty`，`run` 默认也是交互的。若某些终端下 dsh 的 TUI 显示异常，可改用 `docker compose ... run --rm -it dev ...`。
3. **`.env` 的 CRLF**：compose 的 dotenv 解析按行处理，理论上 CRLF 也能用；若发现注入的值带了不可见字符，把 `.env\.env` 存成 LF。

镜像层（`dsh-dev:local`、`node:24-bookworm-slim`）与构建缓存不在本文档清理范围内，需要时用 `docker image rm` / `docker builder prune`。

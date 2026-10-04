# DSH 容器开发环境

把 DSH（DeepSeek Harness）和这个项目跑在同一个容器里，绕开桌面端在 Windows 上的沙箱问题。

组成就三样：**一个工具镜像 + 一层只负责「端口映射 / 挂载卷 / 环境变量」的 docker-compose + 几个一行的 bat**。compose 里**不写 `command:`**，容器永远以镜像默认的 `bash` 启动；真正的启动命令由 bat 在 `docker compose run ... dev <命令>` 里传进去（例如执行 `sh/` 下的脚本）。

**镜像只提供工具，不碰项目**：不拷任何项目文件进镜像，构建时也不执行任何项目命令（没有 `yarn install`、没有 postinstall、没有 `wxt prepare`）。项目通过挂载进容器，依赖要你自己在容器里装。

## 文件说明

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 工具镜像：Node 24 + dsh CLI + git/ripgrep/python3 + pnpm + yarn4 + socat，`CMD ["bash"]` |
| `docker-compose.yml` | **只管端口映射、卷挂载、env_file**，单服务 `dev`，无 `command` |
| `docker-build.bat` | `docker compose ... build`，构建镜像 `dsh-dev:local` |
| `docker-bash.bat` | `docker compose ... run --rm dev bash`，前台 bash 容器 |
| `docker-dsh.bat` | 同上再加 `--service-ports`，启动 `sh/dsh.sh`（socat + dsh web），宿主访问 `http://localhost:3080` |
| `docker-attach.bat` | 连进**唯一**在运行的容器；0 个或多个都报错退出 |
| `sh/dsh.sh` | 容器内启动脚本（socat + dsh web）。其他启动方式照此新增 |
| `.env` / `env.example` | 变量文件，供 compose 插值与注入 |
| `.gitignore` | 忽略宿主侧 `.env/.env` |

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
      - dsh-node-modules:/workspace/node_modules
      - dsh-home:/home/dsh/.dsh
    extra_hosts: ["host.docker.internal:host-gateway"]
```

因此 bat 里不再出现任何 `-p` / `-v` / `-e`，只保留三件事：compose 文件位置、`--env-file`、以及要跑的命令。

> `--env-file` 只影响 `${...}` 插值；变量真正进容器靠服务上的 `env_file: .env`。两者都指向同一个文件。

## 四个 bat 的细节

### docker-build.bat

```bat
docker compose --env-file "%~dp0.env" -f "%~dp0docker-compose.yml" build
```

`%~dp0` 是 bat 所在目录（`.env\`），所以 compose 的 `context: ..` 解析到仓库根目录，`.dockerignore` 生效。

改 dsh 版本：只改 `Dockerfile` 里那一行 `npm install -g "@deepseek-ai/dsh@<版本>"`。版本**只在 Dockerfile 指定**——`.env`、`env.example`、`docker-compose.yml` 都没有它，也没有 build arg。

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
| 卷 `dsh-dev_dsh-home` | 登录凭据、`settings.yaml`、profile、pnpm 装的插件 | `docker volume rm dsh-dev_dsh-home` |
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

`dsh` 的 home 解析顺序为：显式配置 > `$DSH_HOME` > `~/.dsh`。本环境显式把 `DSH_HOME` 设为 `/home/dsh/.dsh`，并挂到 `dsh-home` 卷。

## 目录与卷的对应关系

| 宿主 | 容器 | 说明 |
|---|---|---|
| 仓库根目录 | `/workspace` | bind mount，宿主改代码容器立刻可见（不是卷） |
| 卷 `dsh-dev_dsh-node-modules` | `/workspace/node_modules` | 隔离宿主 `node_modules`：容器里 `yarn install` 的结果落在这里，不往 Windows 写 1.5 万个小文件 |
| 卷 `dsh-dev_dsh-home` | `/home/dsh/.dsh` | 登录凭据、`settings.yaml`、profile、pnpm 装的插件 |

容器内以非 root 用户 `dsh`（uid 1000）运行。`/workspace` 下文件属主跟随宿主；容器内新建的文件在 Windows 上看到属主是 root，属正常现象。

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

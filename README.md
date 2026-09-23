# zed2api

将 Zed 编辑器的 LLM API 代理为 **OpenAI / Anthropic 兼容接口**的本地服务器。单文件二进制，内嵌 Web 管理界面，支持 Docker 部署。

> 授权方式：本项目**不在服务器端执行 GitHub OAuth 登录**。请在 Windows 上运行独立的
> `zed2api-auth` 工具（见 `tools/auth-tool/`）生成 `accounts.json`，然后通过 Web UI 上传到服务器。
> 详见下文 [授权与账号配置](#授权与账号配置)。

## 目录

- [功能](#功能)
- [支持的模型](#支持的模型)
- [快速开始](#快速开始)
- [编译](#编译)
- [使用](#使用)
- [HTTP 接口](#http-接口)
- [授权与账号配置](#授权与账号配置)
- [Docker 部署](#docker-部署)
- [Claude Code 集成](#claude-code-集成)
- [代理设置](#代理设置)
- [鉴权](#鉴权)
- [安全说明](#安全说明)
- [项目结构](#项目结构)

## 功能

- OpenAI 兼容接口：`POST /v1/chat/completions`
- Anthropic 原生接口：`POST /v1/messages`
- 模型列表：`GET /v1/models`
- 多账号管理 + 自动故障转移
- SSE 流式输出：`/v1/chat/completions` 返回 OpenAI `chat.completion.chunk` 和 `[DONE]`；`/v1/messages` 返回 Anthropic `message_*` / `content_block_*` 事件。客户端需选择与 URL 匹配的 API 类型。
- 多模型供应商：Anthropic / OpenAI / Google / xAI
- 扩展思考 (thinking) 支持
- 内嵌 Web UI 管理界面
- **上传授权文件**配置账号（无需在服务器上执行 OAuth）
- HTTPS 代理支持（环境变量 `HTTPS_PROXY`）
- 跨平台：Windows + Linux
- **Docker 部署**

## 支持的模型

| 供应商 | 模型 ID |
|---------|------|
| Anthropic | `claude-opus-4-6`, `claude-opus-4-5`, `claude-opus-4-1`, `claude-sonnet-4-5`, `claude-sonnet-4`, `claude-3-7-sonnet`, `claude-haiku-4-5` |
| OpenAI | `gpt-5.2`, `gpt-5.2-codex`, `gpt-5.1`, `gpt-5`, `gpt-5-mini`, `gpt-5-nano` |
| Google | `gemini-3-pro-preview`, `gemini-2.5-pro`, `gemini-3-flash`, `gemini-2.5-flash` |
| xAI | `grok-4`, `grok-4-fast-reasoning`, `grok-4-fast-non-reasoning`, `grok-code-fast-1` |

完整列表见 [`src/models.json`](src/models.json)，由 `GET /v1/models` 返回。

## 快速开始

```bash
# 1. 编译（需要 Zig 0.15.x + Node.js，详见下文「编译」）
zig build

# 2. 启动服务（默认监听 127.0.0.1:8000）
./zed2api serve

# 3. 在 Windows 上用授权工具生成 accounts.json，然后通过 Web UI 上传
#    打开 http://127.0.0.1:8000 → Accounts → 上传 accounts.json
```

## 编译

需要 [Zig 0.15.x](https://ziglang.org/download/) 和 [Node.js](https://nodejs.org/)（用于构建 Web UI）。

```bash
# 首次需要安装 WebUI 依赖
cd webui && npm install && cd ..

# 编译当前平台（默认会自动构建 WebUI 并嵌入二进制）
zig build

# 交叉编译 Linux x86_64
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe

# 交叉编译 Windows x86_64
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

产物：`zig-out/bin/zed2api`（Windows 下为 `zed2api.exe`）。

### 关于 `-Dwebui`

`build.zig` 提供一个 `webui` 开关（默认 `true`）：

| 值 | 行为 |
|----|------|
| `webui=true`（默认） | 先用 Node 运行 `tsc` + `vite build` 生成 `webui/dist/index.html`，再编译并嵌入 |
| `webui=false` | 跳过 Node 步骤，直接嵌入磁盘上已有的 `webui/dist/index.html` |

Docker 多阶段构建里 WebUI 已在单独阶段构建好，Zig 阶段用 `zig build -Dwebui=false`。

## 使用

```bash
# 启动服务
./zed2api serve [端口]    # 默认 8000，也支持 PORT 环境变量

# 监听所有网卡（Docker / 远程访问需要）
HOST=0.0.0.0 ./zed2api serve

# 从文件导入 accounts.json（替代 Web UI 上传）
./zed2api import [路径]    # 默认读取当前目录的 accounts.json

# 查看账号列表
./zed2api accounts

# 查看帮助
./zed2api help
```

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `PORT` | `8000` | 未传 `[端口]` 参数时的监听端口 |
| `HOST` | `127.0.0.1` | 监听地址；Docker 内需设为 `0.0.0.0` |
| `AUTH_TOKEN` | （空） | **共享访问 token**；设置后所有接口都需要鉴权，详见 [鉴权](#鉴权) |
| `HTTPS_PROXY` | （空） | 上游请求（访问 `cloud.zed.dev`）走的 HTTP/HTTPS 代理 |

打开 `http://127.0.0.1:8000` 进入 Web 管理界面，在 **Accounts** 页上传 `accounts.json`。

## HTTP 接口

### LLM 代理接口

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/v1/chat/completions` | OpenAI 兼容（支持 `stream`、`tools` 等） |
| `POST` | `/v1/messages` | Anthropic 原生 |
| `GET`  | `/v1/models` | 模型列表 |

### 账号 / 管理接口

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET`  | `/` | Web 管理界面（鉴权开启时需登录） |
| `GET`  | `/healthz` | 存活探针（**永远公开**，无需鉴权） |
| `POST` | `/zed/auth/login` | 用 token 换取 `auth` cookie |
| `GET`  | `/zed/accounts` | 列出账号 |
| `POST` | `/zed/accounts/upload` | 上传 `accounts.json`（覆盖现有账号） |
| `POST` | `/zed/accounts/switch` | 切换当前账号 |
| `POST` | `/zed/accounts/delete` | 删除指定账号 |
| `GET`  | `/zed/usage` | 当前账号用量 |
| `GET`  | `/zed/billing` | 计费 / 订阅信息 |

#### 上传接口示例

支持两种请求体：

```bash
# 方式 A：直接上传 accounts.json 原文
curl -X POST http://127.0.0.1:8000/zed/accounts/upload \
  -H 'Content-Type: application/json' \
  --data-binary @accounts.json

# 方式 B：包装在 accounts_json 字段里（Web UI 使用的形式）
curl -X POST http://127.0.0.1:8000/zed/accounts/upload \
  -H 'Content-Type: application/json' \
  -d "{\"accounts_json\": $(jq -c . accounts.json)}"
```

成功返回 `{"success":true,"count":N,"accounts":[...]}`，格式错误返回 `400`。

## 授权与账号配置

服务器本身不执行浏览器 OAuth，授权文件在 Windows 上单独获取后上传。

### 1. 编译授权工具（Windows）

```powershell
cd tools\auth-tool
zig build
# 产物：tools\auth-tool\zig-out\bin\zed2api-auth.exe
```

### 2. 生成 accounts.json

```powershell
.\zed2api-auth.exe [账号名]
```

会打开隐私浏览器窗口完成 GitHub/Zed 登录，成功后在当前目录生成 `accounts.json`。
多次登录会**合并**到同一个文件（支持多账号）。可省略账号名，默认用 GitHub user_id。

### 3. 上传到服务器

任选其一：

- **Web UI**：打开服务器管理界面 → Accounts → "Upload accounts.json"（支持拖拽与点击浏览）。
- **CLI 导入**：`./zed2api import accounts.json`
- **手动挂载/拷贝**：把 `accounts.json` 放进数据目录（Docker 下挂载的 `/data`）。

### accounts.json 格式

```json
{
  "accounts": {
    "my-account": {
      "user_id": "123456",
      "credential": {
        "github_user_id": 123456,
        "github_user_login": "username",
        "access_token": "zed_token_here"
      }
    }
  }
}
```

完整示例见 [`accounts.example.json`](accounts.example.json)。**上传会覆盖服务器现有的账号列表。**

## Docker 部署

仓库根目录提供 `Dockerfile`（多阶段构建）与 `docker-compose.yml`。

```bash
# 构建并启动（默认监听宿主机 8000）
docker compose up -d --build

# 自定义宿主机端口 + 开启鉴权（生产环境强烈建议）
ZED2API_PORT=9000 ZED2API_TOKEN="$(openssl rand -hex 24)" docker compose up -d --build

# 查看日志 / 健康状态
docker compose logs -f
docker compose ps
```

- 容器内服务绑定 `0.0.0.0:8000`，由 Docker 端口映射控制对外暴露。
- 运行时数据（`accounts.json` 等）持久化在 `./data` 卷，首次启动后通过 Web UI 上传账号文件。
- 容器以非 root 用户 `zed2api`（uid 10001）运行：entrypoint 先以 root 修正 `/data` 属主，再用 `gosu` 降权 —— 所以即使宿主机以 root 建了 `./data`，上传也不会再报 `cannot write accounts.json`。
- 健康检查打 `/healthz`（永远公开），与鉴权和账号解耦：开启 `AUTH_TOKEN` 后容器仍能正常判为 healthy。**这只是进程存活探针**，不能证明 Zed 上游、账号或模型请求正常。Web UI 的 Health Check 会分别检查这些路径，模型列表可能回退至缓存或内嵌列表，响应头 `X-Models-Source` 标明 `upstream` / `cache` / `stale` / `static`。

若 Health Check 的模型或 Token 检查失败，请先检查 `docker compose logs --tail=100 zed2api`，再检查容器是否能访问 `cloud.zed.dev`；宿主机代理并不会自动成为容器代理，必要时给 Compose 配置容器可访问的 `HTTPS_PROXY`。不要在日志、截图或工单里粘贴授权文件、JWT、共享 token。

### 构建阶段说明（`Dockerfile`）

| 阶段 | 基础镜像 | 作用 |
|------|----------|------|
| `webui` | `node:22-bookworm-slim` | `npm ci && npm run build` 生成 `webui/dist/index.html` |
| `zig-builder` | `debian:bookworm-slim` | 下载 Zig 0.15.x，`zig build -Dwebui=false -Dtarget=x86_64-linux` |
| `runtime` | `debian:bookworm-slim` | 装 `ca-certificates curl tzdata gosu`，放入二进制 + entrypoint，非 root 运行 |

### 上游代理

若服务器需要走代理访问 `cloud.zed.dev`，在 `docker-compose.yml` 里设置 `HTTPS_PROXY`：

```yaml
environment:
  HTTPS_PROXY: "http://host.docker.internal:7890"   # Docker Desktop 上的 Clash / v2ray
  # Linux 宿主机上可改成宿主机的局域网 IP
```

## Claude Code 集成

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8000
export ANTHROPIC_AUTH_TOKEN=dummy
claude
```

## 代理设置

设置 `HTTPS_PROXY` 环境变量即可让上游请求走代理。

```bash
export HTTPS_PROXY=http://127.0.0.1:7890
./zed2api serve
```

## 鉴权

默认情况下服务**无鉴权**（向后兼容本地/内网用途）。设置环境变量 `AUTH_TOKEN` 即可给所有接口加一道共享 token 门槛 —— 一个 token 同时保护 API 和 Web UI，配置最简单，适合个人部署。

### 启用

```bash
# 本地二进制
AUTH_TOKEN="$(openssl rand -hex 24)" ./zed2api serve

# Docker：用 compose 的 ZED2API_TOKEN 透传到容器的 AUTH_TOKEN
ZED2API_TOKEN="$(openssl rand -hex 24)" docker compose up -d --build
```

### API 客户端如何带 token

任选一种（两种完全等价）：

```bash
# Authorization: Bearer
curl -H "Authorization: Bearer <token>" http://你的服务器/v1/chat/completions ...

# 或 x-api-key
curl -H "x-api-key: <token>" http://你的服务器/v1/chat/completions ...
```

Claude Code：

```bash
export ANTHROPIC_BASE_URL=http://你的服务器
export ANTHROPIC_AUTH_TOKEN=<你的 AUTH_TOKEN>   # SDK 会以 Bearer 形式发送
claude
```

### 浏览器如何登录

打开 Web UI 会看到登录页，粘贴 token 提交即可 —— 服务器种一个 `HttpOnly; SameSite=Strict` 的 `auth` cookie（30 天），之后该浏览器自动带凭证。也可以直接访问 `http://你的服务器/?token=<token>` 用 URL 登录。

### 豁免路径（无需 token）

只有以下路径永远不需要 token：

- `GET /healthz` —— 容器健康检查探针
- `POST /zed/auth/login` —— 登录提交本身
- `OPTIONS *`、`/api/event_logging/batch`、`/v1/messages/count_tokens` —— 无副作用的桩响应

其它一切（`/v1/*`、`/zed/*`、`GET /`）开启 `AUTH_TOKEN` 后都需要凭证。

## 安全说明

⚠️ **不设置 `AUTH_TOKEN` 时上传接口无鉴权**：任何能访问服务端口的人都能通过 `/zed/accounts/upload` 替换服务器的 `accounts.json`、或白嫖你的 API。生产部署请务必：

- **设置 `AUTH_TOKEN`**（见上「鉴权」）。
- 不要把服务端口直接暴露到公网；推荐在前面加 Nginx / Caddy 反向代理并上 HTTPS（token 明文走 HTTP 会被中间人截获）。
- 若要更细粒度控制，可在反代层对 `/zed/*` 再叠加 IP 白名单。

## 项目结构

```
src/
  main.zig       - 入口，CLI 命令（serve / import / accounts）
  server.zig     - HTTP 服务器，路由，账号接口（含上传/删除），共享 token 鉴权
  stream.zig     - SSE 流式代理
  socket.zig     - 跨平台 Socket I/O（Windows ws2_32 / POSIX）
  zed.zig        - Token 管理，计费查询，代理编排
  proxy.zig      - HTTPS 代理检测，curl HTTP 客户端
  providers.zig  - 多供应商请求构建 & 响应转换
  accounts.zig   - 账号管理，JSON 持久化
  auth.zig       - RSA 密钥对，OAuth 登录，浏览器启动（仅授权工具使用）
  models.json    - 内嵌模型列表
webui/           - Vite + TypeScript Web UI（编译为单 HTML 文件嵌入二进制）
webui/src/auth.ts - 客户端鉴权辅助（token 存储 + 登录）
tools/auth-tool/ - 独立的 Windows 授权工具，生成 accounts.json
Dockerfile       - 多阶段构建（Node 构建 WebUI → Zig 编译 → 精简运行时）
docker-entrypoint.sh - 容器入口：root 修 /data 属主后 gosu 降权
docker-compose.yml - 一键部署，带健康检查与数据卷
accounts.example.json - accounts.json 示例格式
```

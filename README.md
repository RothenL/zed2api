# zed2api

将 Zed 编辑器的 LLM API 代理为 OpenAI / Anthropic 兼容接口的本地服务器。单文件二进制，内嵌 Web 管理界面。

## 功能

- OpenAI 兼容接口：`POST /v1/chat/completions`
- Anthropic 原生接口：`POST /v1/messages`
- 模型列表：`GET /v1/models`
- 多账号管理 + 自动故障转移
- SSE 流式输出
- 多模型供应商：Anthropic / OpenAI / Google / xAI
- 扩展思考 (thinking) 支持
- 内嵌 Web UI 管理界面
- **上传授权文件**配置账号（无需在服务器上执行 OAuth）
- HTTPS 代理支持（环境变量 `HTTPS_PROXY`）
- 跨平台：Windows + Linux
- **Docker 部署**

> 授权方式：本项目不再在服务器端执行 GitHub OAuth 登录。请在 Windows 上运行独立的
> `zed2api-auth` 工具（见 `tools/auth-tool/`）生成 `accounts.json`，然后通过 Web UI 上传到服务器。
> 详见下文 [授权与账号配置](#授权与账号配置)。

## 支持的模型

| 供应商 | 模型 |
|---------|------|
| Anthropic | claude-opus-4-6, claude-opus-4-5, claude-sonnet-4-5, claude-sonnet-4, claude-haiku-4-5 等 |
| OpenAI | gpt-5.2, gpt-5.1, gpt-5, gpt-5-mini, gpt-5-nano 等 |
| Google | gemini-3-pro-preview, gemini-2.5-pro, gemini-3-flash 等 |
| xAI | grok-4, grok-4-fast-reasoning, grok-code-fast-1 等 |

## 编译

需要 [Zig 0.15.x](https://ziglang.org/download/) 和 Node.js。

`zig build` 会自动编译 WebUI 并嵌入二进制文件，无需手动操作。

```bash
# 首次需要安装 WebUI 依赖
cd webui && npm install && cd ..

# 编译（当前平台）
zig build

# 交叉编译 Linux x86_64
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe
```

## 使用

```bash
# 启动服务
./zed2api serve [端口]    # 默认 8000，也支持 PORT 环境变量

# 监听所有网卡（Docker / 远程访问需要）
HOST=0.0.0.0 ./zed2api serve

# 从文件导入 accounts.json（替代上传）
./zed2api import [路径]    # 默认 accounts.json

# 查看账号列表
./zed2api accounts
```

打开 `http://127.0.0.1:8000` 进入 Web 管理界面，在 **Accounts** 页上传 `accounts.json`。

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
多次登录会合并到同一个文件（支持多账号）。可省略账号名，默认用 GitHub user_id。

### 3. 上传到服务器

任选其一：

- **Web UI**：打开服务器管理界面 → Accounts → "Upload accounts.json"（支持拖拽）。
- **手动挂载/拷贝**：把 `accounts.json` 放进数据目录（Docker 下挂载的 `/data`）。
- **CLI 导入**：`./zed2api import accounts.json`

> `accounts.json` 格式见 `accounts.example.json`。上传会覆盖服务器现有的账号列表。

## Docker 部署

仓库根目录提供 `Dockerfile`（多阶段构建）与 `docker-compose.yml`。

```bash
# 构建并启动（默认监听宿主机 8000）
docker compose up -d --build

# 自定义宿主机端口
ZED2API_PORT=9000 docker compose up -d --build
```

- 容器内服务绑定 `0.0.0.0:8000`，由 Docker 端口映射控制对外暴露。
- 运行时数据（`accounts.json` 等）持久化在 `./data` 卷，首次启动后通过 Web UI 上传账号文件。
- 若服务器需要走代理访问 `cloud.zed.dev`，在 `docker-compose.yml` 里设置 `HTTPS_PROXY`（例如宿主机上的 Clash 用 `http://host.docker.internal:7890`）。

```bash
# 查看日志 / 健康状态
docker compose logs -f
docker compose ps
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

## 项目结构

```
src/
  main.zig       - 入口，CLI 命令
  server.zig     - HTTP 服务器，路由，账号接口（含上传/删除）
  stream.zig     - SSE 流式代理
  socket.zig     - 跨平台 Socket I/O（Windows ws2_32 / POSIX）
  zed.zig        - Token 管理，计费查询，代理编排
  proxy.zig      - HTTPS 代理检测，curl HTTP 客户端
  providers.zig  - 多供应商请求构建 & 响应转换
  accounts.zig   - 账号管理，JSON 持久化
  auth.zig       - RSA 密钥对，OAuth 登录，浏览器启动（仅授权工具使用）
  models.json    - 内嵌模型列表
webui/           - Vite + TypeScript Web UI（编译为单 HTML 文件嵌入二进制）
tools/auth-tool/ - 独立的 Windows 授权工具，生成 accounts.json
Dockerfile       - 多阶段构建（Node 构建 WebUI → Zig 编译 → 精简运行时）
docker-compose.yml - 一键部署，带健康检查与数据卷
```

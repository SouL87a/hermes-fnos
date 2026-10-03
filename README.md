# Hermes Agent · 飞牛 fnOS 原生版

把 [Nous Research 开源的 Hermes Agent](https://github.com/NousResearch/hermes-agent) 打包成飞牛 fnOS 的**原生第三方应用**（非 Docker）：

- 服务端跑在 NAS 上，浏览器 / 飞牛桌面里直接用 **Hermes 原生 dashboard**——配置、API Key、会话管理、内嵌终端
- 数据与工作区保存在 NAS 上，手机 / 平板 / 电脑共用一份
- **非 Docker**：**自带 CPython 运行时**（含较新 SQLite），运行期零联网、零 pip
- 走飞牛**统一网关**（Unix Socket + 飞牛登录态），不暴露局域网端口
- **支持在线更新**：在 dashboard 内或 SSH 里一条命令，即可更新到上游新版本（代码 + 依赖）

> 本仓库只做 NAS 侧的移植与打包，不修改 Hermes 本身。上游代码：[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)（MIT）。

## 与飞牛应用商店官方包 `trim.hermes` 的关系

飞牛商店官方包（`trim.hermes`，维护者 DavidChen）**用的是同一套架构**：一个网关适配层代理 Hermes 原生 dashboard。但它**把 Python 3.11 焊死在包里**，而新版 Hermes 的 46 个核心依赖要求 Python 3.14 —— 所以它**锁死在 0.20 版，无法更新**（`hermes update` 被硬拦、`/api/hermes/update` 返回"去应用中心更新"）。

本仓库沿用同一架构，但换掉了三样东西：

| 组件 | 官方 `trim.hermes` | 本仓库 |
|---|---|---|
| 运行时 | Python 3.11.15（焊死） | **CPython 3.12.14**（自带，可随上游演进） |
| 网关适配 | Go 静态二进制（含版本锁，**改不了**） | **Python `gateway-proxy.py`**（明文，无锁） |
| 更新 | 拦截（返回"去应用中心更新"） | **真实在线更新**（git 拉取 + 重装依赖） |

架构同构：

```
cmd/main
  └─ gateway-proxy.py        ← 替代官方 Go wrapper：监听 socket、剥前缀、发 X-Forwarded-Prefix、隧道 WS
        └─ hermes dashboard  ← 原生 dashboard（:19119，仅绑回环），即 UI
```

**为什么 Python 代理不会有性能问题**：代理层不解析、不转换、不压缩，只做 `recv → send` 字节转发 + 加一个 header。这是纯 IO 等待，瓶颈在 NAS 网络/磁盘而非 CPU；asyncio 单进程处理几千并发连接是常态，而这里只有几个浏览器在连。真正的好处是**可读可改**——Go 二进制里编译死的锁，在 Python 里就是几行代码。

## 在线更新

两种方式，都是"git 拉取新代码 + 重装依赖"（Python 运行时本身不更新，随 fpk 走）：

**1. dashboard 内**：打开 `https://<NAS>/app/hermes/__hermes/update/ui`，点「检查更新」→「立即更新」。

**2. SSH 命令**：

```bash
hermes-update check     # 检查是否有新版本
hermes-update apply     # 应用更新
hermes-update status    # 查看状态与最近一次结果
hermes-update version   # 打印当前版本
```

更新通道（`update.json` 或环境变量 `HERMES_UPDATE_CHANNEL`）：

| channel | 含义 |
|---|---|
| `main`（默认） | 跟 main 分支最新提交 |
| `stable` | 跟最新稳定 tag（如 `v2026.9.24`） |
| `canary` | 跟最新 canary tag（预发布快照） |

更新后**需重启应用**生效（应用中心 → 已安装 → Hermes → 重启）。依赖安装失败会**自动回滚**到原版本；被中断的更新（代码已切、依赖没装完）下次 `apply` 会识别并只补依赖。

> 更新需要 NAS 能访问 GitHub。国内网络慢时可设 `HERMES_PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple` 加速依赖安装。

## 为什么必须自带 Python

ZCode 能"纯打包"是因为它复用应用中心的 `nodejs_v22`；**Hermes 没有商店可用的 Python 运行时**，所以必须自带一整套：

| | ZCode（NAS-ZCode） | Hermes（本仓库） |
|---|---|---|
| 运行时 | 纯 Node，复用商店 `nodejs_v22` | **自带 CPython 3.12**（python-build-standalone） |
| 依赖 | 官方预编译 runtime 包 | 构建时用 uv 装进 CPython 的 site-packages，随包分发 |
| 前端 | 上游自带 `--web` | 构建时 `npm --workspace web build` → `web_dist/` |
| 网关接入 | 代理改写 HTML 根路径 | **原生前缀反代**：代理发 `X-Forwarded-Prefix` 即可，无需改写 HTML |
| 源码树 | 官方 runtime 包 | **保留 `.git`**（在线更新靠它） |

## 关于 Python 版本

**本仓库用上游 stable 的 `v2026.9.24`**（`requires-python = ">=3.11,<3.14"`），自带 `python-build-standalone` 的 **CPython 3.12.14**。

为什么是 3.12 而不是 3.14：
- stable 要求 `>=3.11,<3.14`，**3.14 超出范围**（canary 才要求 `<3.15`）；
- 3.12 是上游 stable 的实测主力版本，`>=3.11,<3.14` 里离下限/上限都有余量；
- 全部 48 个依赖都有 cp312 manylinux wheel → 构建零源码编译（跨架构可移植性靠这个）。

**另一个关键点 —— SQLite**：Python 自带的 `sqlite3` 只是个壳，真正的能力来自它链接的 `libsqlite3`。应用中心的 Python 3.12 链的是系统库 **3.40.1**，会命中 Hermes 的 WAL-reset 门（安全窗口 `[3.44.6,3.45.0) ∪ [3.50.7,3.51.0) ∪ ≥3.51.3`）→ `state.db` 降级为 `journal_mode=DELETE`，且 doctor 的 FTS 探针（用了 3.42+ 才有的 `flush`）会**误报**「state.db FTS 损坏」。`python-build-standalone` 的 CPython 静态内嵌较新的 SQLite，**实测 3.12.14 = 3.53.1**，过门、WAL 正常。这正是默认走自带模式的核心原因。

### 运行时模式（默认自带，可选复用系统）

| 模式 | 触发 | 说明 |
|---|---|---|
| **自带 CPython 3.12**（默认） | 直接构建 | 随包分发 CPython 3.12.14（PBS），运行期**零联网、零 pip**，不依赖 NAS 上装了什么。**自带 SQLite 3.53.1**，WAL 正常、doctor 无假 FTS 报错 |
| 复用系统 Python | `HERMES_USE_SYSTEM_PYTHON=1` | 用系统 python3（需 3.11–3.13），包体积小（~127MB）；但**依赖要在安装时联网装**（uv 在 NAS 上建 venv），且系统 libsqlite3 偏旧（Debian 12 = 3.40.1）→ state.db 降级 DELETE、doctor 报假 FTS 损坏 |

> 上游 stable 要求 `Python >=3.11,<3.14` → 自带模式只能选 3.11 / 3.12 / 3.13（**3.14 超出范围**）。默认 3.12.14 = 上游实测主力版本，48 个依赖全部有 cp312 manylinux wheel、零源码编译。
>
> 可用 `HERMES_PY_VERSION=3.13.15`（实测 SQLite 同为 3.53.1）或 `HERMES_PBS_TAG=YYYYMMDD` 覆盖。

## 安装

1. 从 [Releases](../../releases) 下载 `hermes-<版本>.fpk`；
2. 应用中心 → 手动安装 → 选择 fpk 文件；
3. 安装完成后从桌面图标打开（iframe 内嵌）；
4. 首次打开在控制台里配置模型与 API Key（`hermes model` 等价的操作在 Web 界面里完成）。

**无需填访问令牌** —— 应用走飞牛统一网关，鉴权用飞牛登录态。

## 网关接入原理

```
飞牛桌面 iframe
   │  /app/hermes/**（飞牛网关校验登录态后转发，带 X-Trim-* 身份头）
   ▼
hermes.sock（Unix Socket，由 gateway-proxy.py 监听）
   │  剥掉 /app/hermes 前缀 + 发 X-Forwarded-Prefix: /app/hermes
   ▼
127.0.0.1:9119（hermes dashboard，uvicorn 仅绑回环）
```

**为什么不改写 HTML**：Hermes 的前端是 React Router SPA，其 API/WS 基址取自 `index.html` 里注入的 `window.__HERMES_BASE_PATH__`，而该值由服务端**依据请求头 `X-Forwarded-Prefix`** 生成（见上游 `hermes_cli/dashboard_auth/prefix.py`）。代理只需带上这个头，服务端会自己改写资产 URL 并注入正确的 base path。比 ZCode 的方案更干净。

**为什么只绑回环**：Hermes 从 2026-06 的 hermes-0day 加固起，一旦绑非回环地址就**强制要求 auth provider**（`--insecure` 已被忽略）。绑回环则不做 auth 门，把鉴权交给飞牛网关。

## 构建

前置：`bash`、`curl`、`tar`、`git`、`python3`（仅构建脚本自用）、`node`/`npm`（前端构建）、`uv`（可选，装了更快）。

```bash
# 完整构建（会克隆上游、下载 CPython、装依赖、构建前端、打包）
bash packaging/fnOS/scripts/build.sh

# 复用已有源码树
bash packaging/fnOS/scripts/build.sh --src /path/to/hermes-agent

# 跳过前端构建（复用已有 web_dist）
bash packaging/fnOS/scripts/build.sh --skip-web

# 复用系统 Python（需 3.11–3.13），不打包 CPython（注意：系统 SQLite 偏旧，WAL 会降级）
HERMES_USE_SYSTEM_PYTHON=1 bash packaging/fnOS/scripts/build.sh

# 覆盖版本号 / CPython 版本 / PBS 标签
HERMES_VERSION=0.2.0 bash packaging/fnOS/scripts/build.sh
HERMES_PY_VERSION=3.13.15 HERMES_PBS_TAG=20260929 bash packaging/fnOS/scripts/build.sh
```

产物：`packaging/fnOS/dist/hermes-<version>.fpk`。

`fnpack` 可用时走 `fnpack build`；否则回退 tar 等价打包（fpk 就是 tar.gz，布局与 fnpack 产物一致）。

## 目录结构

```
packaging/fnOS/
├── manifest                  # 应用元信息（platform=x86、网关声明、9119）
├── cmd/                      # 生命周期脚本（main / install / upgrade / uninstall / config）
│   └── main                  # 含 update 子命令
├── config/                   # privilege（run-as: package）与 resource（共享目录 + hermes-update 命令）
├── ui/config                 # 飞牛桌面入口（iframe → 统一网关）
├── wizard/                   # 安装向导与应用设置页
├── ui-images/                # 图标
├── scripts/build.sh          # 构建脚本
├── scripts/gateway-proxy.py  # 网关适配层（Unix Socket → 回环 TCP）+ 更新控制端点
└── scripts/hermes-update.py  # 在线更新引擎
fnos.version                  # fpk 版本号（单一事实来源）
upstream.version              # 钉住的上游 ref
```

包内布局（`app/` → `app.tgz`）：

```
app/
├── runtime/
│   ├── python/       # CPython 3.12（可重定位，自带 SQLite 3.53.1）
│   ├── hermes-git.git/  # 上游 .git（移出工作树，供在线更新 + 堵 hermes update 自伤）
│   ├── hermes/       # 上游源码树（含 .git，供在线更新）
│   ├── web_dist/     # 预构建前端
│   └── deps.txt      # 依赖清单（系统 Python 模式用）
├── gateway-proxy.py
├── hermes-update.py
├── bin/hermes-update # CLI 包装（usr-local-linker 注册进 PATH）
└── ui/{config,images}
```

## 构建已验证

在 WSL（Ubuntu 24.04 / Linux）上完成了**完整构建**，产出 `hermes-0.1.0.fpk`（160MB）：

| 验证项 | 结果 |
|---|---|
| CPython 3.12.14 下载/解包 | ✅ 自带 pip |
| **依赖全部安装，零源码编译** | ✅ 48 个依赖全有 cp312 manylinux wheel（`--only-binary=:all:`） |
| cp312 wheel | ✅ `cryptography` / `pydantic-core` / `pillow` / `psutil` / `ruamel-yaml` 全有 |
| **SQLite** | ✅ 自带 **3.53.1**，过 Hermes 的 WAL-reset 门（CI 里会实跑断言） |
| glibc | ✅ CPython 仅需 **GLIBC_2.17**（fnOS 2.36） |
| `hermes_cli.main` 导入 | ✅ |
| `hermes dashboard` 子命令 | ✅ |
| 前端构建（web_dist） | ✅ 3.2MB |
| **fpk 产物结构** | ✅ 与官方包一致（manifest/cmd/config/ui/wizard + app.tgz） |

## 已知风险 / 待真机验证

1. ~~**CPython 依赖的 wheel 可用性**~~ —— **已实测通过**（见上表）。头号风险已解除。
2. **首次启动耗时**。Hermes 有 ~2000 个 Python 模块，冷启动 + SQLite 建库可能十几秒；`cmd/main` 的就绪探测给了 90 秒。
3. **WebSocket 鉴权**。回环绑定时 dashboard 会给 index.html 注入一次性 `__HERMES_SESSION_TOKEN__` 供 `/api/ws` 用；需实测代理透传下 WS 握手是否通过。
4. **PM 自管理**。Hermes 自带 `pm` 工具链会管理 venv/node/uv/ripgrep/ffmpeg。本方案用 `HERMES_HOME` / `HERMES_WEB_DIST` / `--skip-build` 绕开它的自安装路径，但需确认 dashboard 路径确实不会触发联网安装。
5. **`install_dep_apps = nodejs_v22` 是否必要**。前端已预构建，dashboard 大概率不需要 Node；但**在线更新重建前端需要 npm**，所以保留声明更稳。
6. **代码体量**。~17000 文件、源码树 + CPython + 依赖 + `.git`，包体积预计 400MB+。
7. **在线更新的网络依赖**。`apply` 需要 NAS 能访问 GitHub（git fetch）与 PyPI（装依赖）。国内建议配 `HERMES_PIP_INDEX` 镜像。
8. **系统 Python 模式的额外代价**（若用 `HERMES_USE_SYSTEM_PYTHON=1`）：安装时要联网装依赖，依赖 NAS 上 Python 的可用性与版本（3.11–3.13），且系统 `libsqlite3` 偏旧（Debian 12 = 3.40.1）→ WAL 降级 DELETE + doctor 假 FTS 报错。

## 后续

- arm64 支持（当前 `platform = x86` 单架构；`HERMES_ARCH=aarch64` 可构建，但需真机验证）
- messaging 网关（Telegram / Discord / Slack 等）——需要额外 extra，验收面更大
- 模型 / API Key 的向导式配置（当前在 dashboard 内完成）

## 许可

- Hermes Agent：[MIT](https://github.com/NousResearch/hermes-agent/blob/main/LICENSE)（© Nous Research）
- 本仓库的移植与打包脚本：MIT
- 图标来自 Hermes 官方资源，版权归 Nous Research 所有

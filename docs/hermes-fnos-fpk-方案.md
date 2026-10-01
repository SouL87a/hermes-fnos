# Hermes Agent → 飞牛 fnOS 原生 fpk：可行性与落地方案

- 评估对象：[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)（MIT，钉 canary tag `v0.21.4+canary.20261001T070239Z`，提交 `da1a5834`，**Python 3.14**）
- 参考实现：[veenyi/fnos-hermes-agent](https://github.com/veenyi/fnos-hermes-agent)（社区版，见 §6）
- 参考实现：**飞牛应用商店官方包 `trim.hermes` 0.20.2-2**（见 §7，**锁 0.20 的根因**）
- 目标：飞牛 fnOS 原生应用包，**不使用 Docker**，走**飞牛统一网关**
- 首版范围（已确认）：**dashboard + 统一网关**，**x86_64 单架构**，**构建时 uv 预装依赖随包分发**
- 本地可复用资产：`NAS-ZCode/packaging/fnOS/`（生产级 Node 应用打包模板 + `gateway-proxy.mjs`）、fnOS fpk 布局知识
- 日期：2026-10-01

---

## 1. 结论

**能做，但它和 ZCode 不是一个量级的工作 —— ZCode 是"打包"，Hermes 是"移植"。**

关键差别：**Hermes 是 Python 3.14 + Node 双栈**，而飞牛应用中心**只有 Node 运行时（`nodejs_v22` / `nodejs_v24`），没有 Python**。ZCode 能纯打包是因为它复用商店的 Node；Hermes 必须**自带一整套 CPython 运行时 + 依赖**。

好消息是**网关接入反而比 ZCode 更干净**：Hermes 原生支持路径前缀反代。

---

## 2. 关键事实（已核实）

### 2.1 Hermes 侧

| 事实 | 出处 |
|---|---|
| 运行时：**Python 3.14**（canary tag）+ Node | `.python-version` / `pyproject.toml` |
| **3.14 未进 stable tag**：stable `v2026.9.24` = `>=3.11,<3.14`；canary `v0.21.4+canary.20261001T070239Z` = `>=3.11,<3.15` + 46 个依赖带 3.14 标记 | 多 tag 对比实测 |
| 上游**不给预编译 runtime**，官方安装靠 `uv` 现拉 CPython + pip 装依赖 | `README.md` 安装段、`setup-hermes.sh` |
| Web 服务：**FastAPI + uvicorn**，默认 `127.0.0.1:9119` | `hermes_cli/web_server.py`、`hermes_cli/subcommands/dashboard.py` |
| **绑回环不做 auth 门；绑非回环强制 auth provider**（`--insecure` 已被忽略，2026-06 hermes-0day 加固） | `web_server.py:should_require_auth` |
| **原生支持前缀反代**：读 `X-Forwarded-Prefix` 头，据此改写 index.html 资产 URL 并注入 `window.__HERMES_BASE_PATH__` | `hermes_cli/dashboard_auth/prefix.py`、`web_server_dashboard.py:mount_spa` |
| 前端 SPA 的 API/WS 基址取自 `window.__HERMES_BASE_PATH__` | `web/src/lib/api.ts:readBasePath` |
| 前端构建：`npm run build --workspace web` → 输出 `hermes_cli/web_dist/` | `web/package.json`、`web/vite.config.ts:build.outDir` |
| `--skip-build` 可跳过前端构建，直接服务已有 dist（需 `HERMES_WEB_DIST` 指向它） | `main_dashboard.py:_resolve_dashboard_web_dist` |
| 只认的环境变量：`HERMES_HOME` / `HERMES_PYTHON` / `HERMES_WEB_DIST` / `HERMES_SERVE_HEADLESS` | `config.py`、`main_dashboard.py` |
| 官方 Docker 布局：`HERMES_HOME=/opt/data`、`HERMES_PYTHON=/opt/hermes/.venv/bin/python`、s6-overlay 监督树 | `Dockerfile`、`docker-compose.yml` |
| 依赖：~40 个**精确钉版**（`==X.Y.Z`）的 Python 依赖；`[web]` extra = fastapi/uvicorn/starlette/python-multipart | `pyproject.toml` |
| 原生轮子依赖：pydantic-core、cryptography、Pillow、psutil、ruamel.yaml | `pyproject.toml` |
| 进程模型：dashboard 会 spawn 子进程（pty/session reaper） | `web_server.py:run_reaper` |
| 体量：~17000 文件、~2000 个 Python 模块 | 本地克隆 |

### 2.2 飞牛 fnOS 侧（沿用 NAS-ZCode 的实测结论）

| 事实 | 来源 |
|---|---|
| `fpk` = `tar.gz`；布局：`manifest`、`ICON.PNG`、`ICON_256.PNG`、`cmd/`、`config/`、`wizard/` 在包根；应用内容树放 `app/`；`app/ui/config` 必须在 `app/` 内 | NAS-ZCode build.sh |
| **fnpack 会把 `app.tgz` 里的文件权限拍平成 0666、目录 0777** | 同上 |
| `install_init` 阶段 `TRIM_APPDEST` 还不存在，检查它会以 10237 中止安装 | 同上 |
| `TRIM_SYS_ARCH` / `platform` 取值是 `x86` / `arm` | 本地 fpk 实证（magicmail、fn-knock） |
| **不能用 `kill -0` 判活**（EPERM 与"不存在"无法区分）→ 用 `/proc` + cmdline 绝对路径匹配 | NAS-ZCode cmd/main |
| **进程匹配串必须是绝对路径**（避免误伤容器进程） | 同上 |
| `runuser` 会清环境 → 环境变量必须写在 `bash -c` 内部 | 同上 |
| `status`：运行 exit 0，未运行 **exit 3** | 飞牛规范 |
| 系统是 Debian 12（bookworm），glibc 2.36 | NAS-ZCode 记录 |
| 统一网关：`ui/config` 声明 `gatewayPrefix` / `gatewaySocket`，网关转发到 Unix Socket 且**不剥前缀** | 本地 fpk 实证 + NAS-ZCode |
| 网关校验 NAS 会话后转发 `X-Trim-*` 身份头 | NAS-ZCode gateway-proxy.mjs |

---

## 3. 方案：自带 Python 运行时 + 回环 dashboard + 网关代理

```
飞牛桌面 iframe
   │  /app/hermes/**（飞牛网关校验登录态后转发，带 X-Trim-*）
   ▼
hermes.sock（gateway-proxy.py 监听 Unix Socket）
   │  剥 /app/hermes 前缀 + 发 X-Forwarded-Prefix: /app/hermes
   ▼
127.0.0.1:9119（hermes dashboard，uvicorn 仅绑回环）
```

### 3.1 包结构

```
<stage>/
├── manifest
├── ICON.PNG / ICON_256.PNG
├── cmd/{main,install_init,install_callback,upgrade_init,upgrade_callback,
│        uninstall_init,uninstall_callback,config_init,config_callback}
├── config/{privilege,resource}
├── wizard/{install,config}
└── app/                       # → app.tgz
    ├── runtime/
    │   ├── python/            # python-build-standalone CPython 3.14（可重定位）
    │   ├── hermes/            # 上游源码树（钉 upstream.version）
    │   └── web_dist/          # 预构建前端
    ├── gateway-proxy.py       # 统一网关适配层
    └── ui/{config,images}
```

### 3.2 为什么不用 venv

venv 的 `pyvenv.cfg` 与 `bin/` 符号链接带构建机绝对路径，装到 NAS 后路径变化会失效。python-build-standalone 的 CPython 本身是**可重定位**的，直接把依赖装进它的 site-packages 最稳。启动命令直接用 `runtime/python/bin/python3`。

### 3.3 启动命令（cmd/main）

```sh
cd "${SRC_DIR}" && exec env \
HOME="${DATA_DIR}" \
PYTHONPATH="${SRC_DIR}" \
HERMES_HOME="${DATA_DIR}" \
HERMES_WEB_DIST="${WEB_DIST}" \
"${PY}" -m hermes_cli.main dashboard \
  --host 127.0.0.1 --port "${PORT}" --no-open --skip-build
```

### 3.4 网关接入（比 ZCode 更干净）

**不需要 HTML 改写**。代理只做两件事：剥前缀 + 发 `X-Forwarded-Prefix: /app/hermes`。服务端据此改写 index.html 的资产 URL 并注入 `window.__HERMES_BASE_PATH__`，SPA 的所有 API/WS 请求自动带上前缀。

`gateway-proxy.py` 是 `gateway-proxy.mjs` 的 Python asyncio 移植（包里已有 Python，不必为代理再拉 Node），逻辑逐条对齐：
- 监听 Unix Socket（0666）；
- 剥 `/app/hermes` 前缀转发到 `127.0.0.1:PORT`；
- WebSocket upgrade 原样管道；
- 可选 `HERMES_GATEWAY_REQUIRE_TRIM=1` 强制只有带 `X-Trim-*` 的网关请求才放行。

---

## 4. 风险与实测结论

### 4.1 已实测通过（Linux / WSL）

| 项 | 结论 |
|---|---|
| CPython 3.14.7（python-build-standalone） | 下载解包正常，自带 pip 26.2.1 |
| **49 个直接依赖 + 66 个传递依赖** | **全部安装成功，零源码编译**（`--only-binary=:all:`） |
| cp314 wheel 可用性 | `cryptography==50.0.1`、`pydantic-core==2.46.4`、`pillow==12.3.0`、`psutil==7.2.2`、`ruamel-yaml==0.18.16` 等均有 cp314 wheel |
| glibc 兼容 | CPython 二进制仅需 **GLIBC_2.17**（fnOS 是 2.36，余量充足） |
| `hermes_cli.main` 导入 | ✅ 全依赖链在 cp314 上可用 |
| `hermes dashboard --host/--port/--no-open/--skip-build` | ✅ 参数齐全 |
| `cmd/main` 启动命令构造 | ✅ 语法正确 + 真实路径可启动 |

> **头号风险（cp314 wheel 缺失）已解除。** 这在 Windows 上测不出来（wheel 平台不同），只有 Linux 测得准。

### 4.2 前端构建的两个坑（已修进 build.sh）

1. **必须用上游入口** `hermes_cli.main_web_build._build_web_ui`，不能裸 `vite build` —— 它要准备图标（`web/public/favicon.ico`）、做 TypeScript 类型检查、解析 workspace 工具。
2. **`npm ci/install` 必须加 `--ignore-scripts`** —— 某些包的 postinstall（如 `unicode-animations`）会联网下载资源而**挂死**（实测 CPU 0s、十几分钟不动）；上游 `package.json` 自己也把它禁了（`allowScripts: {unicode-animations: false}`）。
3. 上游构建内部走 **`npm ci`**（会删 `node_modules` 全新装），慢网络下很耗时 —— 这正是**生产环境必须预构建 `web_dist` 打进包**、而非在 NAS 上构建的原因。
4. 国内建议设 `HERMES_NPM_REGISTRY=https://registry.npmmirror.com`（实测 npm ci 走镜像 1 分钟完成 1327 包）。

### 4.3 仍待真机验证

1. **首次启动耗时**。~2000 模块冷启动 + SQLite 建库，`cmd/main` 给了 90 秒就绪探测。
2. **WebSocket 鉴权**。回环绑定时 dashboard 仍注入一次性 `__HERMES_SESSION_TOKEN__` 供 `/api/ws`；需实测代理透传下 WS 握手通过。
3. **PM 自管理**。Hermes 自带 `pm` 会管理工具链；本方案用 `HERMES_HOME`/`HERMES_WEB_DIST`/`--skip-build` 绕开，需确认 dashboard 路径不触发联网安装。
4. **`install_dep_apps = nodejs_v22`**。前端已预构建，dashboard 运行不需要 Node；但**在线更新重建前端需要 npm**，故保留声明。
5. **包体积**。源码树 + CPython + 依赖 + `.git`，预计 400MB+。

---

## 5. 落地顺序

1. **最小闭环**（本仓库当前状态）：`hermes dashboard` + 统一网关，x86_64 单架构，真机验收网关能开、SPA 能加载、WS 能连。
2. 加 arm64（`HERMES_ARCH=aarch64`）。
3. 加 messaging 网关（`hermes gateway run`）+ 向导式模型/API Key 配置。

---

## 6. 参考实现对比：veenyi/fnos-hermes-agent

调研了社区已有的 [veenyi/fnos-hermes-agent](https://github.com/veenyi/fnos-hermes-agent)（钉 `0.20.0` = tag `v2026.8.3`）。它**走的是另一条路线**，核心差异：

| | veenyi 路线 | 本仓库路线 |
|---|---|---|
| Python 来源 | **复用系统 `/usr/bin/python3`**（3.11–3.13），安装时 `uv venv` + `uv pip install` | **自带 CPython 3.14** |
| 依赖安装时机 | **安装时联网**（阿里云/清华 PyPI 镜像） | **构建时预装**，随包分发，运行期零联网 |
| 交互层 | **自建 Node 服务（`app/server/monitor.js`）+ 自定义 UI（`app/ui`）** | **无自建层**，直连 `hermes dashboard` |
| 端口 | 8650（UI）/ 8742（gateway）/ 9219（dashboard） | 9119（仅回环） |
| manifest | `micro_app = true`，无 `service_port` | `service_port`/`gatewayPrefix`/`gatewaySocket` |
| 上游获取 | 内置完整源码 `app/hermes-src`，`uv pip install -e`（editable） | 内置源码树 + 只装依赖（非 editable） |

**它的 `app/ui` 那层是你不想要的** —— 那是个自定义聊天前端 + Node monitor 服务，把 Hermes 的 dashboard 包了起来。本仓库**不复制这层**，直接用 Hermes 原生 dashboard，靠飞牛统一网关的 `X-Forwarded-Prefix` 前缀反代接入。

**它的可借鉴点**：
- 证明**系统 Python + `uv venv` 在飞牛上可行**（所以本仓库提供了 `HERMES_USE_SYSTEM_PYTHON=1` 模式）。
- 国内 PyPI 镜像（`PIP_INDEX_URL` / `UV_INDEX_URL` 指清华/阿里云）—— 系统 Python 模式值得照抄。
- 它踩过的坑：`install_init` 阶段清残留进程/socket、`port-guard` 误杀本包进程（按 APP_DIR/DATA_DIR 路径豁免）。

**它的隐患**（本仓库有意规避）：
- `uv pip install -e` 的 editable 安装依赖源码树路径稳定 —— 它把源码放 `TRIM_APPDEST`（升级会整体覆盖），路径虽不变但**升级时若 venv 不重建会指向旧代码**。
- 依赖安装放在安装回调里**联网**，安装时长与成功率受网络影响（它自己也在 CHANGELOG 里记录过大量「uv 安装失败」）。
- 钉的是旧版 `0.20.0`，且用系统 Python —— 一旦上游 3.14 迁移打 tag，它的路线会先撞墙。

---

## 7. 飞牛应用商店官方包 `trim.hermes` 0.20.2-2（拆包结论）

拆了飞牛应用商店官方发布的 `trim.hermes` 0.20.2-2 fpk（维护者 DavidChen）。

### 7.1 实际架构：Go wrapper 直接代理**原生 dashboard**

> 初版分析曾误判为"自建 UI 控制面"，后经二进制字符串核实修正。

| 组件 | 形态 | 是否在用 |
|---|---|---|
| `wrapper/trim-hermes-wrapper` | **Go 静态二进制**（go1.24.3，6.6MB） | **是** —— `cmd/config` 启动的就是它 |
| `server/trim_hermes_server.py` | Python 控制面（2688 行） | **否** —— wrapper 里 `trim_hermes_server` 命中 **0 次**，是随包附带但未启用的死代码 |
| `web/` | 自建控制面板（1529 行 app.js） | **否** —— wrapper 不 serve 任何自建静态文件 |
| `runtime.tgz` | 嵌套压缩包（176MB），安装时才解压 | Python 3.11.15 + Node 22.22.3 + uv 0.11.6 + 全部依赖 |

wrapper 的字符串里含 `hermes_cli.main`、`HERMES_PYTHON=`、`HERMES_WEB_DIST=`、`dashboard-host/port`、`injectDashboardLocale`、`dashboardBaseURL` —— 它**自己 spawn `hermes dashboard` 并代理到原生 dashboard**，还往 HTML 注入一段 locale 设置脚本。

**所以官方包 = 一个 Go 网关适配器代理 Hermes 原生 dashboard。** 本仓库同构，只是把 Go 二进制换成 Python。

构建信息（`runtime/BUILD-INFO.json`）：基础镜像 `python:3.11-slim-bookworm-amd64`，钉 Hermes `v2026.8.16`（0.20.2），extras = `web,cron,pty,mcp,acp,messaging,feishu,dingtalk`，PyPI 走清华镜像，构建于 2026-08-17。

### 7.2 为什么锁 0.20、不能更新（根因）

**根因是 Python 版本**：

| | 官方包钉的 0.20.2 | 新版 Hermes（canary/main） |
|---|---|---|
| `requires-python` | `>=3.11,<3.14` | `>=3.11,<3.15` |
| 依赖的 `python_version >= '3.14'` 标记数 | **0** | **46**（openai、pydantic、cryptography、httpx、rich、Pillow…） |

新版把 46 个**核心依赖**加了 3.14 门禁 —— 在 Python 3.11 上这些依赖**整条被跳过**。上游注释：`3.11 is an install bridge for pre-PM updaters, never a runtime`。所以包内那份 3.11 运行时**物理上跑不了新版**。

再加三道显式闸门（都编译死在 Go wrapper 里，**无法修改**）：
- `hermes update` → 退出码 64，提示 "managed by fnOS"；
- `/api/hermes/update` → 返回 `docker_update_unsupported`；
- 环境变量 `HERMES_MANAGED_BY=trim.hermes`。

**结论：官方包要跟新版，必须（1）换掉 Python 运行时 3.11 → 3.14、（2）重装依赖、（3）绕开 Go wrapper 的锁。** 本仓库三条都做了。

### 7.3 可借鉴点（已吸收）

- **`HERMES_BUNDLED_*` 资源定位机制**：官方 `hermes-env` 脚本用一组环境变量指向随包资源（`HERMES_BUNDLED_SKILLS` / `HERMES_OPTIONAL_SKILLS` / `HERMES_BUNDLED_PLUGINS` / `HERMES_BUNDLED_LOCALES` / `HERMES_OPTIONAL_MCPS` / `HERMES_WEB_DIST`）。这是**上游官方支持**的机制，比靠 `PROJECT_ROOT` 推导更稳 —— 已加进 `cmd/main` 的启动环境。
- **`HERMES_WRITE_SAFE_ROOT`** 限定写入安全根到 workspace —— 已加。
- 网关侧：socket 放应用目录下、`gatewayPrefix=/app/...`、`X-Forwarded-Prefix` —— 与本仓库同构。

### 7.4 本仓库的不同做法

- **用 Python `gateway-proxy.py` 替代 Go wrapper** —— 包里已有 Python，不必额外编译/分发二进制；**关键是可改**（Go 二进制里编译死的锁，在 Python 里就是几行代码）。
- **不做运行期版本锁** —— 数据目录（`TRIM_PKGVAR`）独立于代码。
- **实现真实在线更新** —— 见 §8。

---

## 8. 在线更新

上游的 `hermes update` **不能直接用**：它是 git-源码更新器，要求 `PROJECT_ROOT/.git` 存在，否则 Linux 上 `sys.exit(1)` 提示 "Not a git repository. Please reinstall"；且它走 `pm.sync_venv()`，假设有标准 venv —— 本包是"自带 CPython + 依赖装进其 site-packages"，没有 venv。

所以自实现 `hermes-update.py`（按用户选定：**真·git 检出 + 同步重装依赖 + Python 不升级**）：

1. 解析目标 ref（channel: `main` / `stable` / `canary`）
2. `git fetch` + `git reset --hard FETCH_HEAD`（代码原地更新；`--hard` 不动 gitignore 的 `web_dist`/`node_modules`）
3. 从新 `pyproject.toml` 抽依赖 → pip/uv 重装进自带 CPython
4. 有 node/npm 就重建 `web_dist`，没有则保留旧 dist 并警告
5. 写状态文件，提示重启

**健壮性设计**：
- 依赖安装失败 → `git reset` 回旧提交 + 重装旧依赖（**自动回滚**）
- 记录 `deps_commit`：被中断的更新（代码已切、依赖没装完）下次 `apply` 能识别并**只补依赖**
- annotated tag 用 `^{}` 解引用取真实 commit，避免把"同一个 tag"误判成有更新

**入口**：
- CLI `hermes-update {check|apply|status|version}`（`usr-local-linker` 注册进 PATH）
- 控制端点 `/__hermes/update/{check,apply,status,version,ui}`（由 `gateway-proxy.py` 处理，**仅 `X-Trim-Isadmin` 放行**；`apply` 只接受 POST）
- 自包含更新页 `/__hermes/update/ui`（零依赖 HTML，不改 dashboard 原生 HTML）

# Hermes Agent · 飞牛 fnOS 原生版

把 [Nous Research 开源的 Hermes Agent](https://github.com/NousResearch/hermes-agent) 打包成飞牛 fnOS 的**原生第三方应用**（非 Docker）：

- 服务端跑在 NAS 上，浏览器 / 飞牛桌面里直接用 **Hermes 原生 dashboard**——配置、API Key、会话管理、内嵌终端
- 数据与工作区保存在 NAS 上，手机 / 平板 / 电脑共用一份
- **非 Docker**：安装时按官方流程创建独立 Python 环境（不依赖 NAS 上装了什么）
- 走飞牛**统一网关**（Unix Socket + 飞牛登录态）；可选开启 `http://<NAS>:9119` 局域网直连（共用面板密码）
- **支持在线更新**：源码带 `.git`，在 dashboard 内或 SSH 里执行 `hermes update` 即可跟随上游

> 本仓库只做 NAS 侧的移植与打包，不修改 Hermes 本身。上游代码：[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)（MIT）。

## 与飞牛应用商店官方包 `trim.hermes` 的关系

飞牛商店官方包（`trim.hermes`，维护者 DavidChen）**用的是同一套架构**：一个网关适配层代理 Hermes 原生 dashboard。但它**把 Python 3.11 焊死在包里**，而新版 Hermes 的 46 个核心依赖要求 Python 3.14 —— 所以它**锁死在 0.20 版，无法更新**（`hermes update` 被硬拦、`/api/hermes/update` 返回"去应用中心更新"）。

本仓库沿用同一架构，但换掉了三样东西：

| 组件 | 官方 `trim.hermes` | 本仓库 |
|---|---|---|
| 运行时 | Python 3.11.15（焊死） | **跟随上游 pm/lock.json**（当前 3.14.9） |
| 网关适配 | Go 静态二进制（含版本锁，**改不了**） | **Python `gateway-proxy.py`**（明文，无锁） |
| 更新 | 拦截（返回"去应用中心更新"） | **上游 `hermes update`**（git 拉取 + PM 同步依赖） |

架构同构：

```
cmd/main
  └─ gateway-proxy.py        ← 替代官方 Go wrapper：监听 socket、剥前缀、发 X-Forwarded-Prefix、隧道 WS
        └─ hermes dashboard  ← 原生 dashboard（:19119，仅绑回环），即 UI
```

**为什么 Python 代理不会有性能问题**：代理层不解析、不转换、不压缩，只做 `recv → send` 字节转发 + 加一个 header。这是纯 IO 等待，瓶颈在 NAS 网络/磁盘而非 CPU；asyncio 单进程处理几千并发连接是常态，而这里只有几个浏览器在连。真正的好处是**可读可改**——Go 二进制里编译死的锁，在 Python 里就是几行代码。

## 在线更新

用上游原生命令即可（源码在数据目录且带 `.git`）：

```bash
hermes update --check    # 检查是否有新版本
hermes update            # 应用更新（git 拉取 + PM 同步依赖）
```

也可以在 dashboard 的「系统」页里点检查更新。更新后需重启应用生效。

> 更新需要 NAS 能访问 GitHub。国内网络慢时，在应用设置页填 HTTP 代理，
> 或设置 `HERMES_PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple`。

### 装新 fpk 时（应用中心升级）

> ⚠ **已知平台缺陷**：飞牛应用中心的「本地应用覆盖升级」在部分机器上会在
> "停止应用后、写入新内容前"中止，界面只显示「执行脚本出错且原因未知」，
> 应用停在 stopped、内容仍是旧构建。**同一份 fpk 全新安装则完全正常**
> （已在 NAS 实机对照验证）。
>
> **建议的升级方式**：应用中心 → 卸载 → **选「保留数据」** → 安装新 fpk。
> 数据在 `/vol1/@appdata/hermes`，卸载保留数据不会丢；重装后自动回填。
>
> **排查升级失败时**：看 `<数据目录>/log/upgrade.log`。
> `upgrade_init` / `upgrade_callback` 会各写一行（含时间戳、旧版本、
> runtime 是否存在）；若连第一行都没有，说明平台没走到升级钩子。

## 安装方式：与官方一致

本包**不再预置** Python 运行时、依赖和源码树，改为在安装时按上游官方流程获取：

```
安装期（install_callback → scripts/install-runtime.sh）
  1. 获取 uv（锁定版本 + sha256 校验）
  2. git clone 上游源码 → <数据目录>/src（保留 .git）
  3. 由 Hermes 自带的包管理器创建真实 venv 并装依赖
运行期
  解释器与依赖都在 PM 管理的 venv 里；源码在数据目录，`hermes update` 原生可用
```

| | 旧方案（≤0.22.5-6） | 本方案 |
|---|---|---|
| fpk 体积 | 197 MB | **约 5 MB** |
| Python / 依赖 | 预置进包 | 安装时获取 |
| 依赖布局 | 扁平 site-packages | **PM 真实 venv**（上游原生形态） |
| 补丁代码 | ~450 行 | **0** |
| 在线更新 | 自研 `hermes-update.py` | **上游 `hermes update`** |
| 安装耗时 | 30 秒 | 1–5 分钟（取决于网络） |

**为什么这样改**：扁平 site-packages 不是上游 PM 认得的形态，导致「按需安装」（20+ 个可选功能首次使用时自动装依赖）全部失效，只能靠补丁绕过。改用真实 venv 后，上游机制原样工作，不再需要任何补丁。

### 网络要求

安装时需联网获取源码、Python 与依赖（约 150–250 MB）。

- **有 HTTP 代理**：在安装向导里填地址，全程走代理（最稳）
- **没有代理**：自动在「直连 + 国内 GitHub 加速镜像」之间**并行竞速**，哪个快用哪个；PyPI 走清华镜像
- 单路下载 20 秒内平均低于 20 KB/s 会被判定为龟速并主动放弃，不会卡住

安装失败时，可到「应用设置」补代理后重启应用重试；启动流程会检测环境缺失并自动补齐。

### 关于 Python 与 SQLite

Python 版本由上游 `pm/lock.json` 决定（v0.22.5 为 3.14.9），不写死在本仓库。上游发新版时自动跟随。

`python-build-standalone` 的 CPython 静态内嵌较新的 SQLite（实测 3.53.1），过 Hermes 的 WAL-reset 门（安全窗口 `[3.44.6,3.45.0) ∪ [3.50.7,3.51.0) ∪ ≥3.51.3`）。系统 Python 3.11/3.12 链接的 libsqlite3 是 3.40.1，会命中危险区 → `state.db` 降级为 `journal_mode=DELETE`，因此**不使用系统 Python**。

## 访问方式（两条，共用同一套密码）

| 方式 | 地址 | 说明 |
|---|---|---|
| **飞牛桌面图标** | `/app/hermes` | 走飞牛统一网关（iframe），仍需输入面板密码 |
| **局域网直连** | `http://<NAS地址>:9119` | 直接访问 dashboard，输入同一套用户名/密码 |

两条路径都受**面板密码**保护。密码在**安装向导**里设置（**可选**），之后可在应用**设置**页修改。

- 安装时留空 → 只允许飞牛桌面访问（更安全，开箱即用）
- **升级安装时留空不会清除已有密码** —— 清除只能去设置页把两项都清空

**为什么需要密码**：本包需要支持 `http://<NAS>:9119` 直连，dashboard 必须监听局域网地址；Hermes 自 2026-06 安全加固起**强制要求**非回环绑定必须启用登录（`--insecure` 已失效），否则拒绝启动。本包使用上游内置的 basic auth provider。

**未设置密码时**：dashboard 自动退回仅绑 `127.0.0.1`（只有飞牛网关能访问，开箱即用、无需登录）。

**密码规则**（受上游实现约束，已实测）：
- 至少 8 位，最长 128 位；可用中文、空格、`#`、`"`、`'`、`\`、`$`、反引号。
- **首尾空格会被自动去掉** —— 上游读取密码时执行 `strip()`，保留它们只会导致登录失败。

**端口被占用时**：若 `9119` 已被其他应用占用，启动会**自动降级**为仅回环（飞牛网关照常可用），
并在 `info.log` 写明占用进程；腾出端口后重启即可恢复直连。

> ⚠ 直连端口会暴露到局域网：密码请设强一些；不需要直连时可以把密码清空（设置页两项都留空并重启），即退回仅网关模式。

> ⚠ **直连是明文 HTTP**：面板密码在登录时以明文过网，同一局域网内可被嗅探。
> 仅建议在可信内网使用；如需在不可信网络访问，请走飞牛桌面图标（网关入口），
> 或在飞牛/路由器防火墙里把 `9119` 限制到指定来源网段。

> 说明：`/api/status` 是上游设计为免登录的存活探针（version / 内存 / 平台状态）。
> 直连启用后它对局域网可读，但不含会话内容；其余业务接口未登录一律 401。

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

前置：`bash`、`curl`、`tar`、`git`、`python3`（构建脚本自用）、`node`/`npm`（前端构建）。

```bash
# 完整构建（克隆上游源码、构建前端、打包）
bash packaging/fnOS/scripts/build.sh

# 复用已有源码树
bash packaging/fnOS/scripts/build.sh --src /path/to/hermes-agent

# 跳过前端构建（复用已有 web_dist）
bash packaging/fnOS/scripts/build.sh --skip-web

# 覆盖版本号
HERMES_VERSION=0.2.0 bash packaging/fnOS/scripts/build.sh
```

产物：`packaging/fnOS/dist/hermes-<version>.fpk`（约 5 MB）。

`fnpack` 可用时走 `fnpack build`；否则回退 tar 等价打包（fpk 就是 tar.gz，布局与 fnpack 产物一致）。

## 目录结构

```
packaging/fnOS/
├── manifest                  # 应用元信息（platform=x86、网关声明、9119）
├── cmd/                      # 生命周期脚本（main / install / upgrade / uninstall / config）
├── config/                   # privilege（run-as: package）与 resource（共享目录 + bin/hermes）
├── ui/config                 # 飞牛桌面入口（iframe → 统一网关）
├── wizard/                   # 安装向导与应用设置页
├── ui-images/                # 图标
├── scripts/
│   ├── build.sh              # 构建脚本（源码 + 前端 + 打包）
│   ├── install-runtime.sh    # 安装期：uv → 源码 → PM 建 venv 装依赖
│   ├── gateway-proxy.py      # 网关适配层（Unix Socket → 回环 TCP）
│   ├── web-build.mjs         # 前端构建（注入 /app/hermes 前缀）
│   └── envfile.sh            # .env 读写（与 python-dotenv 逐字节一致）
fnos.version                  # fpk 版本号（单一事实来源）
upstream.version              # 钉住的上游 ref
```

包内布局（`app/` → `app.tgz`）：

```
app/
├── runtime/
│   ├── web_dist/          # 预构建前端（必须随包，NAS 上不保证有 node）
│   └── install-stamp.json # 版本来源戳
├── scripts/install-runtime.sh
├── gateway-proxy.py
├── envfile.sh
├── upstream-ref           # 安装期要 clone 的上游 ref
├── bin/hermes             # CLI 入口（usr-local-linker 注册进 PATH）
└── ui/{config,images}
```

运行期数据（`<数据目录>` = `/vol1/@appdata/hermes`）：

```
src/                  # 上游源码（git clone，带 .git）
installs/<key>/       # PM 管理：facts.json + environments/<gen>/venv
.pm-bootstrapped      # 安装完成标记（可选）
workspace/ state/ log/ .env
```

## 构建已验证

在 WSL（Ubuntu 24.04 / Linux）上完成了**完整构建**，产出 `hermes-0.1.0.fpk`（160MB）：

| 验证项 | 结果 |
|---|---|
| CPython 3.14.7 下载/解包 | ✅ 自带 pip |
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

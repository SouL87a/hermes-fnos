# fnOS Hermes 应用包缺陷报告

| 项目 | 值 |
|---|---|
| **应用名** | `hermes`（飞牛 fnOS 应用中心） |
| **应用包版本** | 0.1.0 |
| **hermes-agent 版本** | `main@357f51c49106f47136caf9b01015467b7b633fe8`（2026-10-01） |
| **构建流水线** | `hermes-fnos`（GitHub Actions，见 `hermes-build.json`） |
| **运行环境** | fnOS / TrimNAS（主机 NAS-SouL87），Debian 12，kernel 6.18.18.c1126-trim |
| **网关路径** | `/app/hermes` → Unix socket `hermes.sock` → `127.0.0.1:9119` |
| **访问地址** | `https://nas.soul87.top:22067/app/hermes/` |
| **报告日期** | 2026-10-01 |

---

## 一、摘要

安装后 Web UI **完全无法正常使用**：主框架能加载，但内容区黑屏、对话页底部终端黑框、消息平台（Gateway）未启动。

经逐层定位，这是 **6 个相互独立的打包缺陷叠加** 的结果 —— 任一未修都会表现为"黑屏"，这也是"修一处不生效"的原因。其中 **4 个属于构建/打包阶段遗漏**，2 个属于启动脚本与代理脚本配置缺失。

**已全部验证并临时修复**（详见第四章），但每次应用更新后会复发，需在打包流水线中根治。

---

## 二、缺陷清单

### 🔴 缺陷 1：前端静态资源 base 路径硬编码为 `/`

**症状**：访问 `https://<host>/app/hermes/`，页面主框架正常，但内容区**完全黑屏**。

**证据**（nginx `error.log` 铁证）：
```
open() "/usr/trim/www/assets/ChatPage-C95Y5X9N.js" failed (No such file or directory)
request: "GET /assets/ChatPage-C95Y5X9N.js HTTP/1.1"
referrer: "https://nas.soul87.top:22067/app/hermes/chat"
```
请求路径是 `/assets/...`（**站点根**），而资源实际在 `/app/hermes/assets/...`。

**根因**：Vite 构建时 `base` 未配置为 `/app/hermes/`，导致产物中的资源拼接函数硬编码为根路径。在 `assets/react-vendor-BoVnYuL4.js` 中可直接读到：
```js
Xt = function(e){ return `/` + e }
```
`__vite__mapDeps` 依赖表项形如 `"assets/ChatPage-C95Y5X9N.js"`（无 `./` 前缀），依赖 base 拼接 —— 拼出的却是 `/assets/...`。

**影响**：**所有通过路径前缀反代访问的部署**，所有懒加载路由（Chat、SYSTEM 等）全部 404 → 黑屏。

**建议修复**：构建时设置 `base: '/app/hermes/'`，或改用 `import.meta.env.BASE_URL` 拼接；同时检查 `__vite__mapDeps` 的 preload 逻辑是否遵循 base。

> ⚠️ `cmd/main` 注释声称"前端是 React Router SPA，原生支持路径前缀反代"，但**实际产物并不支持** —— 注释与实现不符。

---

### 🟠 缺陷 2：静态资源缓存策略阻断修复生效

**症状**：服务端已修复（资源路径已正确），浏览器**仍加载旧资源**，问题持续。

**证据**：资源响应头
```
cache-control: public, max-age=31536000, immutable
```

**根因**：`immutable` + 一年有效期，浏览器不再发起校验请求；`index.html` 虽是 `no-store`（正确），但入口 JS 引用的 vendor 资源被永久缓存。

**影响**：任何前端修复对已访问过的用户**完全不可见**，极易误判为"修复无效"。

**建议**：修复发布时应更换资源 hash（内容变更即 hash 变更，天然失效）；或对修复版本降低缓存策略。

---

### 🔴 缺陷 3：TUI bundle 未打包进应用

**症状**：对话页**底部终端黑框**，无任何输出。

**证据**：`hermes_cli/main_tui_launch.py::_make_tui_argv` 按序查找三处，**全部落空**：

| 查找位置 | 结果 |
|---|---|
| `$HERMES_TUI_DIR/dist/entry.js` | ❌ 环境变量未设置 |
| `hermes_cli/tui_dist/entry.js` | ❌ **文件不存在（打包遗漏）** |
| `<repo>/ui-tui/dist/entry.js` | ❌ 空目录（只有源码，无 node_modules） |

代码注释明确写：**打包安装应自带该文件**。对照组 —— 旧应用 `trim.hermes` 自带该文件（3.7 MB, v0.20.2）。

**根因**：`hermes-fnos` 流水线未执行 TUI 构建，或构建产物未复制到 `hermes_cli/tui_dist/`。

**影响**：对话页终端完全不可用（Dashboard 的核心交互之一）。

**建议修复**：流水线增加 `scripts/build/tui.mjs` 构建步骤，并把 `ui-tui/dist/entry.js` 复制到 `hermes_cli/tui_dist/entry.js`。

---

### 🔴 缺陷 4：TUI 启动未提供 node 路径（回退路径卡死）

**症状**：即使补齐 TUI bundle，终端**仍然黑框**；`/api/pty` 通道能建立但 **0 字节输出**。

**证据**：
- `_tui_node_bin("node")` 优先读 `$HERMES_NODE` → **应用未设置**
- 回退 `pm.ensure("node")` → **实测 240 秒超时（exit 124）**，永久卡死
- node 进程确实被拉起，但状态 `Tl`（挂起），零输出
- 系统本身**有可用 node**：`/vol1/@appcenter/nodejs_v22/bin/node`（v22.18.0）

**根因**：启动脚本未导出 `HERMES_NODE`，而依赖管理器（PM）中无 node 条目 → 回退到"下载 node"路径 → 在离线/受限环境卡死。

**影响**：对话页终端不可用；且**表现为静默挂起**，无任何错误提示，极难排查。

**验证**：手动设置 `HERMES_NODE` 后，解析**立即**返回正确 argv：
```
argv = ['/vol1/@appcenter/nodejs_v22/bin/node', '--expose-gc',
        '/vol1/@appcenter/hermes/runtime/hermes/hermes_cli/tui_dist/entry.js']
cwd  = /vol1/@appcenter/hermes/runtime/hermes/hermes_cli/tui_dist
```

**建议修复**：启动脚本导出 `HERMES_NODE`（可自动探测系统 node）；或在 PM 中预置 node 条目，避免网络回退。

---

### 🟠 缺陷 5：Gateway 未随应用启动

**症状**：Dashboard 显示 `Gateway Status: Stopped`，QQ / Telegram 等消息平台无法连接。

**证据**：`/var/apps/hermes/cmd/main` 只启动两个进程：
```bash
python -m hermes_cli.main dashboard --host 127.0.0.1 --port 9119 --no-open --skip-build
python gateway-proxy.py
```
**没有 `gateway run`**。对照组 —— 旧应用 `trim.hermes` 启动脚本含：
```bash
gateway run --external-supervisor
```

**影响**：应用安装后消息平台**开箱不可用**；需手动调用 `POST /api/gateway/restart` 才能拉起，且**应用重启后回到 Stopped**（状态不持久）。

**建议修复**：启动脚本补充 `gateway run --external-supervisor`（由应用 supervisor 托管生命周期）。

---

### 🔴 缺陷 6：gateway-proxy 未剥离 WS 升级请求的 `Origin` 头

**症状**：经路径前缀反代访问时，**依赖 WebSocket 的页面（对话页 / SYSTEM 页）直接黑屏**。

**证据**（A/B 实测，经 `hermes.sock` 带正确 token）：

| 请求 Origin | 原版代理 | 修补后代理 |
|---|---|---|
| 无 Origin | `101` | `101` |
| loopback Origin | `101` | `101` |
| **外部域名/IP Origin** | **`403`** | **`101`** ✅ |

**根因**：`web_server_chat.py::_ws_host_origin_reason()` 实施 DNS-rebinding 防护（对应安全公告 **GHSA-ppp5-vxwm-4cf7**）：
```python
origin = ws.headers.get("origin", "")
if not origin:
    return None                      # 无 Origin 直接放行
if not _is_accepted_host(parsed.netloc, bound_host, trusted_public_hosts):
    return f"origin_mismatch origin={origin} bound={bound_host}"
```
校验失败后 `_close_unless_sidecar_allowed()` → `close(4403)` → **在 accept 前关闭** → 客户端收到 HTTP 403。

`trusted_public_hosts` 来源于 `dashboard.public_url`；应用数据目录为空 → 集合为空 → **外部 Origin 一律拒绝**。

**影响**：任何经反代（浏览器携带公网/局域网域名 Origin）的 WS 连接被拒 → 对话页、SYSTEM 页黑屏。HTTP 层不受影响（带外部 Origin 的 GET 仍 200），所以表现为"主框架正常、只有依赖 WS 的页面黑屏"。

**建议修复**（二选一）：
1. `gateway-proxy.py` 在 **WS 升级请求**上剥离 `Origin` 头（**HTTP 请求保留不动**，不影响 CSRF 防护）—— 本报告采用的方案；
2. 或为 dashboard 配置 `dashboard.public_url`，使 `trusted_public_hosts` 生效。

> ⚠️ 注意：方案 2 会触发 `should_require_dashboard_auth()` 返回 True（检测到非 loopback public host），**强制开启 OAuth 门禁**；未配置 OAuth 时会锁死 dashboard。因此方案 1 更稳妥。
>
> ⚠️ `cmd/main` 注释声称"代理只要发 `X-Forwarded-Prefix`，服务端就改写…"，但**未处理 Origin**。

---

## 三、影响面：为什么"修一处不生效"

6 个缺陷中有 4 个**都会独立导致黑屏**，形成叠加：

```
浏览器访问 /app/hermes/
   │
   ├─ 缺陷 1  资源 404 ──────────→ 内容区黑屏
   ├─ 缺陷 2  缓存锁死修复 ──────→ 修复不可见（误判"无效"）
   ├─ 缺陷 6  WS 握手 403 ───────→ 对话页 / SYSTEM 页黑屏
   └─ 缺陷 3+4  终端无 node ─────→ 对话页底部终端黑框

缺陷 5（独立）──────────────────→ 消息平台不启动
```

---

## 四、已验证的临时修复

| # | 缺陷 | 修复方式 | 状态 |
|---|---|---|---|
| 1 | WS Origin 校验误杀 | 补丁 `gateway-proxy.py`：WS 升级时跳过 `origin` 头 | ✅ 已生效（403 → 101） |
| 2 | Vite base 硬编码 `/` | 改写产物 preload 函数 base 为 `/app/hermes/` | ✅ 已生效 |
| 3 | `immutable` 缓存 | 资源引用统一加 `?v=2` 强制失效 | ✅ 已生效（0 个新 404，53/53 请求 200） |
| 4 | TUI bundle 缺失 | 本机按源码构建 `entry.js`（3,921,738 字节）并安装 | ✅ 已安装 |
| 5 | `HERMES_NODE` 未设置 | 在 `$HERMES_HOME/.env` 声明 `HERMES_NODE` | ✅ 已验证解析正确 |
| 6 | gateway 未启动 | 启动脚本补 `gateway run`（待实施） | ⚠️ 暂用 API 手动拉起 |

> 注：修复 1/2/3 直接改应用目录文件，**应用更新后会全部丢失**；修复 5 写在数据目录 `.env`（更新不覆盖）。

---

## 五、给打包方的修复建议（按优先级）

| 优先级 | 缺陷 | 建议 |
|---|---|---|
| 🔴 P0 | 缺陷 1 | 构建时设 Vite `base: '/app/hermes/'`；校正 `__vite__mapDeps` 拼接逻辑 |
| 🔴 P0 | 缺陷 3 | 流水线增加 TUI 构建，产物落到 `hermes_cli/tui_dist/entry.js` |
| 🔴 P0 | 缺陷 4 | 启动脚本导出 `HERMES_NODE`（自动探测系统 node） |
| 🔴 P0 | 缺陷 6 | `gateway-proxy.py` 对 WS 升级请求剥离 `Origin` |
| 🟠 P1 | 缺陷 5 | 启动脚本补 `gateway run --external-supervisor` |
| 🟠 P1 | 缺陷 2 | 重新审视资源缓存策略与发布流程 |
| 🟡 P2 | — | 修正 `cmd/main` 注释与实现不符之处 |

---

## 附录 A：环境信息

**两套并存的应用**

| 对比项 | `trim.hermes`（旧） | `hermes`（新） |
|---|---|---|
| 应用包版本 | 0.20.2-2 | 0.1.0 |
| hermes-agent | 0.20.2（v2026.8.16） | main@357f51c4（2026-10-01） |
| Python | 3.11.15 | 3.14.7 |
| 安装方式 | wheel 装入 runtime venv | git 源码树 + 预构建前端 |
| 前端位置 | `runtime/python/share/hermes-agent/web_dist` | `runtime/web_dist` |
| 网关前缀 | `/app/trim-hermes` | `/app/hermes` |
| 内部端口 | 19119 | 9119 |
| 数据目录 | `/vol1/@appdata/trim.hermes/hermes` | `/vol1/@appdata/hermes` |
| gateway run | ✅ `--external-supervisor` | ❌ 缺失 |
| `tui_dist/entry.js` | ✅ 3.7 MB | ❌ 打包遗漏 |

**关键路径**
```
应用根     : /vol1/@appcenter/hermes
HERMES_HOME: /vol1/@appdata/hermes   （/var/apps/hermes/var 符号链接）
Unix socket: /vol1/@appcenter/hermes/hermes.sock
代理脚本   : /vol1/@appcenter/hermes/gateway-proxy.py
前端产物   : /vol1/@appcenter/hermes/runtime/web_dist
启动脚本   : /var/apps/hermes/cmd/main
可用 node  : /vol1/@appcenter/nodejs_v22/bin/node  (v22.18.0)
```

## 附录 B：诊断命令

**经 unix socket 直连 dashboard**
```bash
S=/vol1/@appcenter/hermes/hermes.sock
TOK=$(curl -s --max-time 8 --unix-socket $S http://localhost/ \
      | grep -oE '__HERMES_SESSION_TOKEN__="[^"]*"' | sed 's/.*="//;s/"//')
curl -s --max-time 8 --unix-socket $S http://localhost/api/status
```

**WS 握手 Origin 测试**
```bash
curl -s -i --max-time 8 --unix-socket $S \
  -H "Origin: https://nas.soul87.top:22067" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "http://localhost/api/ws?token=$TOK" | head -1
# 期望 101 Switching Protocols
```

**TUI node 解析**
```bash
cd /vol1/@appcenter/hermes/runtime/hermes
HERMES_HOME=/vol1/@appdata/hermes \
  /vol1/@appcenter/hermes/runtime/python/bin/python3 -c "
import sys; sys.path.insert(0,'.')
from hermes_cli.main_tui_launch import _make_tui_argv
print(_make_tui_argv())"
```

**前端资源可达性**
```bash
grep -c "GET /app/hermes/assets" /usr/trim/nginx/logs/access.log
grep -c "assets/.*failed" /usr/trim/nginx/logs/error.log
```

---

*报告基于 2026-10-01 安装的 `hermes` 0.1.0 实测，所有结论均有命令输出支撑。*

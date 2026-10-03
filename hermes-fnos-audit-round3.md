# fnOS Hermes 自打包版 · 第三轮运行环境审计

- 日期：2026-10-03
- 实例：`hermes`（应用根 `/vol1/@appcenter/hermes`，数据 `/vol1/@appdata/hermes`）
- 版本：`v0.21.4`（`da1a5834`，`updateMechanism: external`，自带 CPython 3.14.7）
- 本轮范围：第二轮的**修复验证** + 前两轮**从未触及的区域**（更新准入、打包产物、跨应用依赖、PM 工具链）
- 全程只读：未重启任何服务、未改配置、未写 install state

---

## 总览

| 项 | 状态 |
|---|---|
| 进程 | dashboard(9119) / gateway-proxy / gateway 各 1，均在跑，etime 16h55m |
| 平台 | qqbot=connected，api_server=connected，telegram=fatal(缺 token，配置项) |
| 数据 | state.db 13 MB + WAL 2.7 MB，正常 |
| 内存 | 常驻 ≈1.2 GB（dashboard 381 MB + gateway 373 MB + TUI 349 MB + node 130 MB） |
| 主机 | swap 2.4G/4.0G 已用、free 492 Mi、load 1.89、/vol1 23% |
| 日志 | errors.log 950 KB，dotenv 噪声 3423 条占绝对多数 |
| 打包体 | app 722 MB（runtime/python 462 MB + runtime/hermes 257 MB，其中 `.git` 82 MB） |
| PM | 依赖环境**已提交**（上轮修复生效），工具链缺 ripgrep / node / npm |

### 与第二轮对比：已确认修好的 5 项

| 上轮 | 现状 | 证据 |
|---|---|---|
| P2 PM 依赖环境未提交 | ✅ 已修 | `action-doctor.log` 20:24:20 起 doctor 正常输出；4 个 `runtime_command` 子进程（doctor / prompt-size / gateway status / update --plan）全部 `PM_ERR=False` |
| P0 在线更新丢前缀 | ✅ 已规避 | `gateway-proxy.py` 接管 `/api/hermes/update` → `hermes-update.py`；`rebuild_web()` 用 `runtime/web-build.mjs` 注入 `base=/app/hermes/` 并断言 `"/app/hermes/assets/" in html` 才放行 |
| P1 更新端点可伪造 | ✅ 已修 | `gateway-proxy.py` 用 `SO_PEERCRED` 取对端 uid，`_is_admin(headers, from_root)` 只信 root 对端；本机直连实测 `403` |
| 慢页面（更新检查） | ✅ 已改 | `UPDATE_CHECK_TTL=600` / `UPDATE_CHECK_FAIL_TTL=90` / 后台异步 kick / 未命中立即返回 `update_available=null` |
| install-stamp 缺失 | ✅ 已有 | `runtime/hermes/install-stamp.json`，`updateMechanism: "external"` |

---

## 【P0】`hermes update` 仍会自伤 —— 准入判定被 `.git` 绕过

**这是本轮最重要的一条，且是第二轮"重新打包"引入的新风险。**

### 证据（真实调用，非推断）

```
sealed_steward(SRC)       = None
detect_install_method     = git
is_commit_build           = False
image_provenance          = None
evaluate_update_admission = None          ← 准入通过，不拒绝
```

`hermes update --plan` 也印证：

```
Update plan:
  Install: git (v0.21.4 @ da1a5834)       ← 被识别为 git 安装，未提示"外部管理"
```

### 根因

`hermes_cli/steward.py:220`：

```python
def sealed_steward(project_root):
    root = Path(project_root)
    if (root / ".git").exists():
        return None            # ← 有 .git 就直接判为"我们的树，可变更"
    distribution = read_install_stamp(root).get("distribution")
    return distribution if ... else "unknown"
```

`update_contract.evaluate_update_admission()` 的 Layer 2 只问 `sealed_steward()`。
**`updateMechanism: "external"` 完全不参与这条判定** —— 它只影响
`_launchers.expose_cli()`（不发布 `~/.local/bin/hermes`）和 `venv_sync.publish_launchers()`。

于是链条变成：包里有 `.git` → `sealed_steward=None` → 准入返回 `None` → `hermes update` 执行
`git fetch` + `reset --hard` + 依赖重装。

### 影响

- `update-state.json` 显示远端 `0a374d167424` ≠ 当前 `da1a58341781`，**有更新可用**，
  在 TUI/CLI 里敲 `hermes update` 是很有诱惑力的动作；
- 一旦执行：`runtime/hermes` 被 `reset --hard` 覆盖（`web-build.mjs` 的 base 注入、`install-stamp.json`、
  `fnos-depenv.py` 的调用点都可能失效），依赖被 pip 重装到自带 CPython；
- 对比第一轮：那时没 `.git`，`hermes update` 是**安全失败**（`✗ Not a git repository`）；
  现在变成了**真的会执行** —— 这是一处回归。

### 修复方案（二选一，都不改上游）

**方案 A（推荐，改动最小且顺带解决包体）** —— 把 `.git` 移出工作树：

1. `mv runtime/hermes/.git runtime/hermes-git.git`
2. `hermes-update.py` 里所有 `git -C SRC ...` 改为带
   `GIT_DIR=<app>/runtime/hermes-git.git` + `GIT_WORK_TREE=<app>/runtime/hermes`
   （或统一在 `run()` 里注入这两个环境变量）；
3. 给 `install-stamp.json` 补 `"distribution": "fnOS App Center"` —— 这样
   `sealed_steward` 会返回该字符串，`hermes update` 被拒绝并打印正确的引导文案。

**方案 B（纯配置）** —— 只做第 3 步是**无效的**（`.git` 优先），必须配合 A 的第 1 步。

### 回归验证（必须做）

移走 `.git` 后 `venv_sync.check_runtime()` 的守卫
（`hermes_cli/venv_sync.py:56`：有 `.git` 且 mechanism≠self 时直接 `return None`）不再成立，
会真正走 `pm.activate()`。需确认它返回空，否则启动会多一条 `install out of sync` 告警。

---

## 【P1】更新检查必然经常失败：超时预算不匹配

### 证据：`git ls-remote` 实测 10 次

```
try1 rc=0 8906ms    try6 rc=0 2080ms
try2 rc=0 2233ms    try7 rc=0 1842ms
try3 rc=0 2307ms    try8 rc=0 1868ms
try4 rc=124 20007ms ← 超时   try9 rc=0 1915ms
try5 rc=0 1813ms    try10 rc=124 20006ms ← 超时
```

超时率 **2/10**，成功时跨度 1.8 s – 8.9 s。远端确实在抖动（与技能里记录的 flapping remote 一致）。

### 根因：两层的超时预算互相打架

| 层 | 常量 | 值 |
|---|---|---|
| `hermes-update.py:213` | `git ls-remote` 的 `timeout=` | **20 s** |
| `gateway-proxy.py:207` | `UPDATE_CHECK_TIMEOUT` | **3 s** |
| `gateway-proxy.py:248` | subprocess 硬超时 | `UPDATE_CHECK_TIMEOUT + 2` = **5 s** |

只要 `ls-remote` 超过 5 s（实测 8.9 s 那次就超了），网关层的 subprocess 就被杀，
检查判失败 → 写入 90 s 的失败缓存 → 这 90 s 内 dashboard 的更新状态一直显示不出来。

### 修复

把 `gateway-proxy.py` 的 `UPDATE_CHECK_TIMEOUT` 默认值从 `3` 提到 **25**
（对齐 `ls-remote` 的 20 s 并留余量）。首屏不会因此变慢 —— 已有"未命中立即返回 null +
后台异步查"的设计，等待只发生在后台线程。若不想等满 25 s，可同时把
`hermes-update.py` 的 `ls-remote` 超时降到 12 s，接受极少数失败。

---

## 【P2】socket 0666 + dashboard 无鉴权 + token 明文（第二轮未修）

```
$ stat hermes.sock
srw-rw-rw- uid=872 gid=876

$ curl -s --unix-socket .../hermes.sock http://localhost/app/hermes/   (2089 字节)
   has_SESSION_TOKEN=True   AUTH_REQUIRED_false=True
```

进程环境里 **`HERMES_GATEWAY_REQUIRE_TRIM` 未设置**（默认 0）：

```
HERMES_GATEWAY_SOCKET=/vol1/@appcenter/hermes/hermes.sock
HERMES_GATEWAY_PREFIX=/app/hermes
HERMES_GATEWAY_DEBUG=1
```

**已缓解部分**：`SO_PEERCRED` 让 `/__hermes/update*` 只信 root 对端（实测本机 403），
所以"任意本机进程触发更新"这条链已断。

**仍成立部分**：任何能连 socket 的进程都能读到明文 session token → 调 `/api/*` →
通过 `/api/pty` 拿到一个等同 `hermes --tui` 的终端 → 以 `hermes` 身份执行命令。
叠加 `ui/config` 的 `allUsers: true`，这是 fnOS 上的一条普通用户提权路径。

**建议**：socket 收到 `0660`（属主 `hermes:hermes`，网关同组即可）——
这一条比开 `REQUIRE_TRIM` 更有效，因为后者只要求带头、本机进程可自加。

---

## 【P2】`.env` 第 4 行语法错误仍在，且已扩散到 CLI

```
行1  comment=True
行2  comment=True
行3  comment=False has_eq=True
行4  comment=False has_eq=False ascii=False   ← 一句漏了 # 的中文说明
行5  comment=False has_eq=True
```

`errors.log` 里 `dotenv.main` **3423 条**，最新 `2026-10-03 14:19:51`，约每分钟一条。

本轮新增影响：它已经跑到 CLI 的 stdout 里 —— `hermes update --plan` 的输出末尾就是
`python-dotenv could not parse statement starting at line 4`，会污染任何解析该输出的自动化。

**修复**：第 4 行行首补 `#`。一行改动，消除 3423 条噪声。

---

## 【P2】跨应用依赖：hermes 的 `/chat` 与 TUI 依赖 `nodejs_v22` 应用

```
HERMES_NODE=/vol1/@appcenter/nodejs_v22/bin/node

cmd/main:find_node_bin() 依次探测：
  /var/apps/nodejs_v22/target/bin/node
  /var/apps/nodejs_v22/bin/node          ← 命中
  /var/apps/nodejs_v24/target/bin/node
  /var/apps/nodejs_v24/bin/node
  /vol*/@appcenter/nodejs_v*/bin/node
```

`runtime/node` 不存在（`MISSING`），包内不含 node。实测 `/chat` 就是
`node tui_dist/entry.js` + `python -m tui_gateway.entry` 两个进程。

**影响**：`nodejs_v22` 被卸载或改路径后，`/chat` 和 `hermes --tui` 直接不可用（有 4 个回退候选，
但没有一个是包自带的）。建议要么把 node 打进包，要么在 `cmd/main` 的启动自检里显式报错，
而不是让 `/chat` 静默黑屏。

---

## 【P2】PM 工具链缺 ripgrep / node / npm —— 已实际影响 agent 能力

```
$ hermes pm doctor
✓ python 3.14.7+202****0901
✓ tirith 0.4.2
✓ uv 0.12.3
✗ node: not installed
✗ npm: not installed
✗ ripgrep: not installed
```

**ripgrep 缺失是实打实的能力损失**：本轮审计中 `search_files` 直接失败并留下

```
WARNING agent.tool_executor: Tool search_files returned error:
{"total_count": 0, "error": "Broad local file search without ripgrep is disabled
 because find cannot keep this traversal safely bounded."}
```

agent 的文件搜索能力因此降级为必须手写遍历。`node`/`npm` 缺失则让包内无法自建 web 产物。

---

## 【P3】其余（含第二轮遗留）

| # | 问题 | 证据 |
|---|---|---|
| 1 | gateway 每次退出都是非零码 | `gateway-exit-diag.log` 最新 `{"tag":"gateway.exit_nonzero","pid":3075995}` @ 2026-10-02T13:25:58 |
| 2 | 代理层无 gzip | `gateway-proxy.py` 中 `gzip`/`Content-Encoding`/`compress`/`zlib` 零命中，dashboard 的 `i18n-*.js` 490 KB 明文走公网 |
| 3 | `tui_gateway_crash.log` 持续膨胀 | 1 106 864 B / 16 643 行，尾部是 `tui_gateway/entry.py:132` 的 `"".join(None)` 上游 bug（已记录，非本包引入） |
| 4 | `.git` 82 MB 占包体 32% | `runtime/hermes` 257 MB 中 `.git` 82 MB；顺带让 `git status` 永远显示 16899 条 modified（fnpack 权限拍平，`core.filemode=true`） |
| 5 | telegram 平台 fatal | `gateway_state.json`: `telegram state=fatal err=missing_credentials`，但 `config.yaml` 里 `telegram.enabled: false` —— 属配置项，非缺陷 |
| 6 | 上游 LLM 网关 503 | `agent.chat_completion_helpers` 57 条 `no_healthy_account`；`192.168.68.68:7864` 账户池问题，非本包 |

---

## 主机级（非 Hermes 缺陷，但会放大上面的问题）

```
load average: 1.89, 1.65, 1.60
Mem: 22Gi total, 10Gi used, 492Mi free, 12Gi buff/cache, 12Gi available
Swap: 4.0Gi total, 2.4Gi used, 1.6Gi free
/dev/mapper/...-0  1.9T  424G  1.4T  23% /vol1
```

swap 已用 60%、free 仅 492 Mi。Hermes 侧常驻约 1.2 GB 且 `/chat` 有 PTY keep-alive 设计
（每次重开 dashboard 新增一个 TUI ≈ 400 MB），在当前内存余量下值得盯一下。

数据目录：`HERMES_HOME` 1.2 GB（`tools/` 868 MB、`cache/` 252 MB），备份与快照合计不到 300 KB。

---

## 优先级行动表

| 优先级 | 事项 | 改动量 | 风险 |
|---|---|---|---|
| **1** | 关闭 `hermes update` 自伤通道（移 `.git` + 补 `distribution`） | 中（脚本 + stamp） | 低，可回滚；需回归 `check_runtime` |
| **2** | `.env` 第 4 行补 `#` | 一行 | 无 |
| **3** | `UPDATE_CHECK_TIMEOUT` 3 → 25 | 一行 | 无（首屏不阻塞） |
| **4** | socket `0666` → `0660` | 一行 | 低；需确认网关同组 |
| **5** | 补装 ripgrep（`pm.ensure('ripgrep')`） | 一条命令 | 低 |
| 6 | 打包时排除 `.git` 或改用独立 `--git-dir` | 打包流程 | 见 P0 方案 A |
| 7 | node 依赖：打进包 或 启动自检报错 | 打包流程 | 中 |
| 8 | gateway 优雅退出 / 代理层 gzip | 代码 | 低优先 |

**建议先做第 1 项** —— 它是唯一"用户一次手滑就自伤"的问题，且随包体积优化一并解决。
第 2、3 项都是一行改动，可同批处理。

---

## 未验证 / 说明

- 本次审计**全程只读**：未重启服务、未改配置、未写 install state、未触发更新。
- **未验证**：fnOS 网关转发到 socket 时 `SO_PEERCRED` 拿到的对端 uid 是否为 0
  （本机直连是 403；若网关侧不是 root，dashboard 的"更新 Hermes"按钮会一直 403）。
  验证需要从浏览器带登录态实测，或读 `/usr/trim/bin/trim_open_gateway` 的实现。
- **未验证**：`hermes update` 的完整执行（只验证了准入判定返回 `None`，即"不会被拒绝"；
  没有真的跑一次自更新）。
- **未验证**：移走 `.git` 后 `venv_sync.check_runtime()` 的行为（方案 A 的回归项）。
- 报告文件：`/vol1/@appshare/hermes/workspace/hermes-fnos-audit-round3.md`
- 本轮探针脚本：`/vol1/@appshare/hermes/workspace/probe/probe{2..8}.py`、`probe_web.py`

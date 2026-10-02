# Hermes 网关诊断报告

- 生成时间：2026-10-02 17:05 (CST)
- 主机：fnOS / TrimNAS（Linux 6.18.18.c1126-trim），服务用户 `hermes`（uid 872）
- 实例：hermes（应用 `/vol1/@appcenter/hermes`），`HERMES_HOME=/vol1/@appdata/hermes`
- 代码版本：0.21.4（commit `da1a5834`）
- 当前网关：PID 2515194，已运行约 20 分钟

---

## 摘要

排查了两个现象，它们是**两个独立的问题**，互无因果：

| # | 现象 | 根因 | 严重度 | 影响 |
|---|---|---|---|---|
| 1 | 网关状态 `Degraded` | `config.yaml` 启用了 telegram，但 `.env` 无 `TELEGRAM_BOT_TOKEN` | 低 | 仅状态标注，QQ / API 服务正常 |
| 2 | 点"重启网关"报 `操作失败 (1)` | PM 依赖环境记录 `facts.json` 缺失，重启子进程一启动即退出 | 中 | **重启按钮完全不可用**（非首次，已持续多日）；不影响运行中网关 |

关键结论：**问题 2 的失败发生在"启动重启命令"阶段，从未触及运行中的网关**。因此关掉 telegram 后重启失败，并不会把网关搞坏 —— 它一直在正常服务。

---

## 问题 1：网关状态 Degraded

### 现象
Dashboard 侧栏显示 `网关状态：Degraded`。

### 根因
`config.yaml` 声明启用 telegram，但未提供凭据，平台连接失败并被 parked，网关把整体状态从 `running` 降级为 `degraded`。

### 证据

**1）状态文件** `/vol1/@appdata/hermes/gateway_state.json`

| 字段 | 值 |
|---|---|
| `gateway_state` | `degraded` |
| `exit_reason` | `null`（非看门狗杀死） |
| `pid` | 2515194（存活） |
| `platforms.qqbot` | `connected` ✅ |
| `platforms.api_server` | `connected` ✅（127.0.0.1:18642） |
| `platforms.telegram` | **`fatal`** — `missing_credentials` / "No bot token configured" ❌ |

**2）启动日志** `/vol1/@appdata/hermes/logs/gateway.log`（16:42:47）

```
ERROR  hermes_plugins.platforms__telegram.adapter: [Telegram] No bot token configured
WARNING gateway.run: ✗ telegram failed to connect
ERROR  gateway.run: 1 configured platform(s) failed to start and are parked (fix the
       reported error, then `hermes gateway restart`): telegram: No bot token configured.
       The gateway is DEGRADED — it serves the remaining platform(s) with those unserved.
INFO   gateway.run: Gateway running with 2 platform(s)
```

**3）代码路径** `gateway/run_startup.py:54-59`

```python
_startup_parked_platforms: bool = False

def _serving_state(self) -> str:
    return "degraded" if self._startup_parked_platforms else "running"
```

**4）配置对账**

- `config.yaml:32-36` → `platforms.telegram.enabled: true`（问题发生时）
- `.env` → telegram 相关键数量 = **0**（只有 `QQ_APP_ID` / `QQ_CLIENT_SECRET` / `API_SERVER_*`）

### 处理状态
已将 `config.yaml` 改为 `platforms.telegram.enabled: false`（已确认落盘）。**该改动需重启后生效**，而重启又撞上问题 2，故状态至今仍是 `degraded`。

### 附带发现（与 Degraded 无关）

1. **QQ 消息被拒**：`logs/gateway.log` 16:43:52 —
   `WARNING gateway.run: Unauthorized user: 1C7FD88C46DD64D410D8A17222C06D2C (None) on qqbot`
   `.env` 未配置任何 `*_ALLOWED_USERS` 白名单，陌生发送者被 pairing 策略拦截。
2. **dotenv 解析告警**：启动 `.env` 时输出
   `python-dotenv could not parse statement starting at line 4` — 该文件第 4 行不是合法 `KEY=VALUE` 形态，该行及其后可能被跳过。

---

## 问题 2：重启网关失败（exit 1）

### 现象
Dashboard 点击"重启网关" → 提示 `重启网关 操作失败 (1)`。

### 根因

**PM（包管理器）从未成功提交过 Hermes 的依赖环境。** 记录文件 `facts.json` 不存在，导致 dashboard 派生的重启子进程在引导阶段就被 PM 的安全检查拒绝，退出码 1。

### 证据

**1）操作日志** `/vol1/@appdata/hermes/logs/gateway-restart.log`

最新两次（用户点击时刻）：

```
=== gateway-restart started 2026-10-02 16:52:21 ===
hermes: no dependency environment is committed for this install; run `hermes pm repair`

=== gateway-restart started 2026-10-02 16:52:55 ===
hermes: no dependency environment is committed for this install; run `hermes pm repair`
```

**该失败并非首次** —— 日志中自 10-01 起共 **7 次**重启尝试，错误完全一致：

```
2026-10-02 00:29:10 / 11:35:09 / 11:35:27 / 13:34:26 / 13:35:24 / 16:52:21 / 16:52:55
```

**2）实测复现**（用 dashboard 派生子进程完全相同的方式）

| 使用的解释器 | `gateway status` 结果 | 退出码 |
|---|---|---|
| `/vol1/@appcenter/hermes/runtime/python/bin/python3`<br>（当前进程所用，非 PM store） | 正常输出状态 | **0** ✅ |
| `/vol1/@appdata/hermes/tools/python-3.14.7+202****0901-linux-x64/bin/python3`<br>（**PM 登记的 store python**） | `no dependency environment is committed for this install` | **1** ❌ |

**3）报错出处** `pm/environments.py:291-302`

```python
def _require_own_dependencies(project_root: Path) -> None:
    """With nothing committed, an interpreter keeps the packages it booted with.
    PM's store Python boots with none, so for it there is nothing to keep: refuse
    instead of running on whatever PYTHONPATH it inherited."""
    import sys
    if sys.prefix != sys.base_prefix:
        return                      # venv 解释器自带依赖 → 放行
    if Path(sys.base_prefix).resolve().is_relative_to(store_root(project_root).resolve()):
        raise RuntimeError("no dependency environment is committed for this install")
```

store python **不是 venv**（实测 `prefix == base_prefix`），且路径位于 store 根下 → 直接抛异常。

**4）缺失的文件**

| 应有 | 实际 |
|---|---|
| `/vol1/@appdata/hermes/installs/5fb99c8db7cd2f76/facts.json` | **不存在** |
| `.../installs/5fb99c8db7cd2f76/environments/<gen>/`（Hermes 依赖 venv） | **`environments/` 目录整个不存在** |
| `.../installs/5fb99c8db7cd2f76/pm-runtime/selected.json` | ✅ 存在 → `generations/a787cac112434e1e949a004863be52a3` |

`install_key` 已核实匹配：`sha256("/vol1/@appcenter/hermes/runtime/hermes")[:16] = 5fb99c8db7cd2f76`。

**5）为什么现有进程没事**

Dashboard 派生重启命令走 `hermes_cli/_launchers.py::runtime_command()` →
`resolve_store_python()`（读 `tools/facts.json` 的 `packages.python.entry`）→ store python →
`hermes_bootstrap.py:563` `activate_dependencies()` → `committed_venv()` 返回 `None`（`facts.json` 缺失）→
`_require_own_dependencies()` 抛错。

而当前运行的网关 / dashboard 进程由 fnOS 应用脚本用 `runtime/python` 直接启动，绕过 PM 选择逻辑，故正常。

**6）PM 状态推断** `installs/5fb99c8db7cd2f76/bootstrap/default.json`

```json
{
  "identity": "da1a58341781c04cfa7cbcfb5160cf7665e16064",
  "bootstrappedAt": "2026-10-02T10:42:12+0800",
  "results": {
    "adopt_blessed_checkout": { "ok": true, "skipped": "already-stamped" },
    "migrate_config":         { "ok": true, "migrated": "37->49" },
    "state_db_guard":         { "ok": true },
    "drop_live_plugin_catalog": { "ok": true },
    "expose_cli":             { "ok": true, "skipped": "externally-owned" }
  }
}
```

时间线：

| 时间 | 事件 |
|---|---|
| 10-01 21:32 | `installs/5fb99c8db7cd2f76/` 创建 |
| 10-02 00:08 | PM 生成 `pm-runtime/generations/a787cac1…` + `selected.json`（仅 PM 自身运行时 venv，**无 Hermes 第三方依赖**） |
| 10-02 10:42 | bootstrap 完成，`expose_cli` 因 fnOS 已自带 CLI 包装而跳过 |
| 10-02 16:42 | 当前网关进程启动（走 `runtime/python`） |
| 10-02 16:52 | 点击重启 ×2，均 exit 1 |

即：**PM 的 bootstrap 在 fnOS 这种"外部托管"部署上没走完依赖提交那一步**，`facts.json` 从未被写出。

### 影响面

- ✅ 运行中网关不受影响（qqbot + api_server 正常，PID 2515194）
- ❌ Dashboard 的**重启 / 更新**按钮均不可用（共用同一套派生机制）
- ⚠️ 任何依赖 `hermes pm` 提交环境的操作都会失败

---

## 修复方案

### 针对问题 1（让 Degraded 消失）—— 需先重启

改动已落盘，任选一种方式重启即可（见下）。

### 针对问题 2 —— 三选一

| 方案 | 操作 | 耗时 | 效果 |
|---|---|---|---|
| **B（推荐，最快）** | fnOS 应用中心：停止 → 启动 hermes 应用 | 秒级 | 立即生效；走 `runtime/python`，绕开 PM 检查 |
| **C（直接可控）** | `kill -TERM 2515194`，由 supervisor 拉起 | 秒级 | 已验证：16:20 该网关正是这样被重启的 |
| **A（治本）** | `cd /vol1/@appcenter/hermes/runtime/hermes && hermes pm repair` | 数分钟（需联网拉依赖） | 修复后 Dashboard 重启按钮恢复可用 |

**推荐组合**：先用 **B 或 C** 让 telegram 关闭生效；若希望 Dashboard 重启按钮长期可用，再执行 **A**。

---

## 附：核实命令清单

```bash
# 状态与进程
cat /vol1/@appdata/hermes/gateway_state.json
ps -o pid,ppid,etime,stat,cmd -p 2515194

# 日志
tail -60 /vol1/@appdata/hermes/logs/gateway.log
tail -30 /vol1/@appdata/hermes/logs/gateway-restart.log

# 配置
sed -n '30,40p' /vol1/@appdata/hermes/config.yaml

# PM 依赖状态
ls -la /vol1/@appdata/hermes/installs/5fb99c8db7cd2f76/
cat /vol1/@appdata/hermes/installs/5fb99c8db7cd2f76/pm-runtime/selected.json
cat /vol1/@appdata/hermes/installs/5fb99c8db7cd2f76/bootstrap/default.json

# 两种解释器对比复现
/vol1/@appcenter/hermes/runtime/python/bin/python3 -I -c "..." gateway status       # exit 0
/vol1/@appdata/hermes/tools/python-3.14.7+*/bin/python3  -I -c "..." gateway status # exit 1
```

# Hermes（fnOS 打包版）「重启网关」按钮故障 — 诊断报告

- 报告时间：2026-10-02 19:30 (CST)
- 环境：fnOS / TrimNAS，主机 NAS-SouL87；应用 `hermes` v0.21.4（打包者 SouL87，`fnpack` 包）
  - 包体（程序）：`/vol1/@appcenter/hermes`（= `/var/apps/hermes/target` 指向）
  - 生命周期脚本：`/var/apps/hermes/cmd/main`（root:root 0755，**不在包体内**）
  - 数据目录：`/vol1/@appdata/hermes`（= `/var/apps/hermes/var`）
- 故障现象：dashboard 点「重启网关」→ `操作失败: 找不到 /vol1/@appcenter/hermes/cmd/main`
- 影响范围：dashboard 的网关启停按钮（restart 已坏；start/stop 机理相同）
- 本次报告期间**未对任何服务做变更**（仅只读检查 + 隔离沙盒实验）

---

## 1. 根因

`gateway-proxy.py` 用 `$HERMES_APP_ROOT` 拼生命周期脚本路径，但 fnOS 的布局里 `cmd/` 不在包体内。

`gateway-proxy.py:108-109`（注释与实现）：

```
# 应用根：本代理脚本部署在 <APP_ROOT>/gateway-proxy.py，cmd/main 在 <APP_ROOT>/cmd/main
APP_ROOT = os.environ.get("HERMES_APP_ROOT") or os.path.dirname(os.path.abspath(__file__))
```

`gateway-proxy.py:387-389`（「重启网关」处理）：

```python
main_sh = os.path.join(APP_ROOT, "cmd", "main") if APP_ROOT else ""
if not main_sh or not os.path.exists(main_sh):
    respond(500, {"ok": False, "message": f"找不到 {main_sh}", "name": "gateway-restart"})
```

实测证据：

| 项目 | 值 | 结果 |
|---|---|---|
| 代理进程 `HERMES_APP_ROOT`（`/proc/2917435/environ`） | `/vol1/@appcenter/hermes` | — |
| 代理拼出的路径 | `/vol1/@appcenter/hermes/cmd/main` | `exists: False` |
| 真实脚本 | `/var/apps/hermes/cmd/main` | `exists: True` |
| `@appcenter/hermes` 实际条目 | `bin/ gateway-proxy.py hermes-update.py hermes.sock runtime/ ui/` | 无 `cmd/` |

`cmd/main` 由 fnOS 部署在 `/var/apps/<app>/cmd/`（应用元数据目录，root 所有），而 `$APP_DIR` 是 `TRIM_APPDEST` = `readlink -f /var/apps/hermes/target` = `/vol1/@appcenter/hermes`。main 启动代理时注入 `HERMES_APP_ROOT='${APP_DIR}'`（`cmd/main:279`），于是代理永远拼出那个不存在的路径。

### 1.1 该按钮从未成功过（历史证据）

`/vol1/@appdata/hermes/logs/gateway-restart.log` 记录了上游 spawn 路径的真实失败：

```
=== gateway-restart started 2026-10-02 00:29:10 ===
hermes: no dependency environment is committed for this install; run `hermes pm repair`
（11:35:09、11:35:27、13:34:26、13:35:24、16:52:21、16:52:55、17:06:41 共 8 次，全部同一错误）
```

机理链条（已在源码中对上）：`/api/gateway/restart` → `_spawn_hermes_action` → `runtime_command`（`hermes_cli/_launchers.py:34`）→ `hermes_bootstrap.py:563 activate_dependencies(_root)` → 本包是「自带 CPython + site-packages」布局，无 PM 提交的依赖环境 → `SystemExit(1)`。

结论：18:55 重装前的旧代理**没有接管**该端点，请求转发到上游 spawn，报 PM 依赖错误；18:55 之后的新代理**接管**了该端点（设计正确），但因路径推导错误改为报「找不到 cmd/main」。**两种失败方式，同一个按钮从未工作。**

---

## 2. 同一 bug 类的其它落点

| 位置 | 状态 | 说明 |
|---|---|---|
| `gateway-proxy.py:387` | **已坏** | 本次故障，活跃路径 |
| `cmd/main:197` `exec '${APP_DIR}/cmd/main' __gateway_supervisor '${ws}'` | 潜在坏 | 仅当 main 以 **root** 运行时走这条（`runuser` 分支）；当前 main 以 hermes 运行走同用户分支，故未暴露 |
| `cmd/main:363` `pkill -TERM -f -- "${APP_DIR}/cmd/main __gateway_supervisor"` | 潜在坏 | 同上的兜底匹配串，永不命中 |

其余由 `APP_DIR` / `APP_ROOT` 推导的路径实测全部存在：

| 路径 | 状态 |
|---|---|
| `runtime/hermes/hermes_cli`、`runtime/python/bin/python3`、`runtime/web_dist/index.html` | EXISTS |
| `hermes.sock`、`gateway-proxy.py`、`hermes-update.py`、`runtime/web-build.mjs` | EXISTS |
| `runtime/node/bin` | MISSING，但只是 `find_node_tool` 的候选之一，另有 `nodejs_v22/v24/target/bin` 与 `/vol*/@appcenter/nodejs_v*/bin` glob 兜底 → 更新链路不受影响 |

---

## 3. 影响面：网关启停三个按钮

前端 `web_dist/assets/api-*.js` 定义了三个动作，代理只接管了其中 1 个：

| 端点 | 代理接管 | 本包上的实际结果 |
|---|---|---|
| `POST /api/gateway/restart` | 是（`gateway-proxy.py:640`） | `找不到 /vol1/@appcenter/hermes/cmd/main`（500） |
| `POST /api/gateway/start` | **否** | 上游 `_spawn_hermes_action` → 与上表 8 次相同的 `no dependency environment is committed` |
| `POST /api/gateway/stop` | **否** | 同上 |

`info.log` 中 start/stop 的轮询记录为 0 次（从未被点击），restart 的轮询记录 18 次。

修好 restart 后的前端行为（已核对上游 `actions.py:get_action_status`）：代理接管的重启不写上游 action 结果，前端轮询 `GET /api/actions/gateway-restart/status` 会拿到 `running:false, exit_code:null` → 立即判定成功，**不会卡圈、不会误报失败**。

---

## 4. 附带验证：重启后 supervisor 归属变化（风险已排除）

`restart_gateway` 会先 `rm gateway.want` 让当前 supervisor（= fnOS 的 `main start` 进程）退出循环，再由新进程接管 supervisor。为此做了隔离沙盒实验（逐行复刻 `gateway_supervisor_loop` + `restart_gateway` 时序，5 轮）：

```
轮次 | 老supervisor退出 | 新supervisor存活 | 存活总数 | gateway启动次数
  1  |  1  |  0  |  1  |  2        （2~5 轮完全相同）
日志： supervisor(old) 启动 gateway → supervisor(old) 退出 → supervisor(new) 启动 gateway
```

结论与配套实测：

- **无双 supervisor 抢拉**：`rm want` 在 kill 之前，老 supervisor 只在 `wait` 返回后检查 want，此时新 supervisor 尚未重建它 → 交接干净，gateway 只被拉起一次。
- bash 退出不等后台任务：`time /bin/bash -c 'sleep 20 & '` → 0.004s 返回 → 代理的 `subprocess.run(timeout=90)` 不会卡超时。
- 后台子 shell 的 argv 完全继承父 bash，故重启后的孤儿 supervisor **不匹配** `PATTERN`(`APP_DIR/runtime`)、`GATEWAY_PATTERN`(`APP_DIR/gateway-proxy.py`)、也不匹配 `cmd/main __gateway_supervisor` → stop 时的 pkill 兜底清不掉它，但它靠 `rm gateway.want` 退出，仍能停干净。
- 只读跑 `main status` → exit 0：状态判定只看 `app.pid` 里的 dashboard 进程，故 main start 进程退出后 fnOS 面板仍显示「运行中」，不影响应用状态。

实验脚本：`/vol1/@appshare/hermes/workspace/.probe/race/race.sh`（可复跑，已清理全部沙盒进程）。

---

## 5. 修复方案

### 方案 A — 运行时补符号链接（立即可用，无需 sudo）

```bash
ln -s /var/apps/hermes/cmd /vol1/@appcenter/hermes/cmd
```

一处链接让 §1、§2 的三处假设同时成立。缺点：重装/升级包时 `@appcenter` 被替换，链接丢失，需重建（可在包内 `cmd/upgrade_callback` 加一行自动重建）。

### 方案 B — 改包代码（治本，需同步回打包源）

**B1. `gateway-proxy.py`**：用候选解析替代单一拼接

```python
def _resolve_cmd_main() -> str:
    """cmd/main 由 fnOS 放在 /var/apps/<app>/cmd/main，不在包体（APP_ROOT）内。"""
    cands = []
    env_dir = os.environ.get("HERMES_APP_CTL_DIR")
    if env_dir:
        cands.append(os.path.join(env_dir, "main"))
    if APP_ROOT:
        cands.append(os.path.join(APP_ROOT, "cmd", "main"))
        cands.append(os.path.join("/var/apps", os.path.basename(APP_ROOT.rstrip("/")), "cmd", "main"))
    for c in cands:
        if c and os.path.exists(c):
            return c
    return cands[0] if cands else ""
```

并把 `:387` 改为 `main_sh = _resolve_cmd_main()`。

**B2. `cmd/main`**（root:root，需 sudo 或经打包升级）

```bash
# 在 APP_DIR 定义之后新增
APP_CTL_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"   # = /var/apps/hermes/cmd
```

- `:197` → `"exec '${APP_CTL_DIR}/main' __gateway_supervisor '${ws}'"`
- `:363` → 匹配串改为 `"${APP_CTL_DIR}/main __gateway_supervisor"`；若同时存在符号链接调用，建议放宽为 `pkill -TERM -f -- "cmd/main __gateway_supervisor"`
- `:279` 注入块新增 `HERMES_APP_CTL_DIR='${APP_CTL_DIR}' \`

**B3.（可选）** 代理一并接管 `/api/gateway/start`、`/api/gateway/stop`，映射到消息网关 supervisor 的启停（写/删 `gateway.want` + 拉/杀 `gateway run`），**不是**停整个 fnOS 应用（应用生命周期归应用中心）。

### 方案 C — 打包侧把 `cmd/` 复制进包体

不推荐：生命周期脚本变成两份，升级时容易漂移。

---

## 6. 修复后的验证方法

1. 只读预检：`test -x /vol1/@appcenter/hermes/cmd/main && echo OK`
2. 端到端：点「重启网关」按钮，或 `bash /var/apps/hermes/cmd/main gateway-restart`
3. 判定标准：`/vol1/@appdata/hermes/info.log` 出现 `gateway restart via cmd/main: ok=True`；`gateway-starts.log` 新增一条时间戳；进程树中 `gateway run --external-supervisor` 的 PID 变化而 dashboard PID 不变。

---

## 7. 结论

- 故障是一个**路径推导错误**：`$APP_ROOT/cmd/main` 在 fnOS 布局下不存在，真实位置是 `/var/apps/<app>/cmd/main`。三处同源（`gateway-proxy.py:387`、`cmd/main:197`、`cmd/main:363`）。
- 该按钮在本包上**从未成功**：旧代理报 PM 依赖错误（8 次实测记录），新代理报找不到脚本。
- 网关 start/stop 两个按钮**尚未被代理接管**，机理相同，预计同样失败（未实测点击）。
- 重启后的 supervisor 归属变化经沙盒实验验证为**干净交接**，无并发抢拉风险。

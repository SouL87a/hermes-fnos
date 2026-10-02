# Hermes fnOS 包：`no dependency environment is committed for this install` 根因与修复

现场：`/vol1/@appcenter/hermes`（应用）+ `/vol1/@appdata/hermes`（数据），
Hermes 0.21.4 @ `da1a5834`，自带 CPython 3.14.7，由 `cmd/main` 以 `runtime/python/bin/python3`
直接启动 dashboard + gateway。

---

## 一、结论

不是依赖缺失，也不是权限问题。**这是本包「自带 CPython、不走 PM 构建」的布局与上游
PM 的一个固有冲突**：PM 自己的 store Python 存在于 `$HERMES_HOME/tools/` 下，上游
`runtime_command()` 会优先用它来拉起子进程，而 PM 又要求那个解释器必须有一个
「已提交的依赖环境」——本包从不创建，于是子进程一律 exit 1。

包内 `cmd/main` 的注释其实已经记录了同一个冲突（针对「重启网关」），并用 supervisor
循环绕过了那一条；但绕过的只是**一个**调用点，其余全部照旧报错。

---

## 二、根因链（每一环都有实测证据）

1. **本包的运行时布局**：`runtime/python` 是可重定位的 python-build-standalone，依赖预装
   在其 `lib/python3.14/site-packages`；不做 `uv venv`，不写 PM 的依赖环境登记。

2. **PM 的 store Python 却存在**：`/vol1/@appdata/hermes/tools/python-3.14.7+…/`
   （由运行期 `pm.ensure()` 拉浏览器工具链时按需下载）。它**不是 venv**：
   ```
   prefix /vol1/@appdata/hermes/tools/python-3.14.7+…-linux-x64
   base   /vol1/@appdata/hermes/tools/python-3.14.7+…-linux-x64
   ```

3. **子进程解释器选择优先 store Python** — `hermes_cli/_launchers.py:44`
   ```python
   python = python or resolve_store_python(root) or Path(sys.executable)
   ```
   `resolve_store_python()`（同文件 `:103`）读 `$HERMES_HOME/tools/facts.json` 的
   `packages.python.entry` → 实测返回：
   ```
   resolve_store_python = /vol1/@appdata/hermes/tools/python-3.14.7+…/bin/python3
   ```

4. **子进程启动即被拒绝** — `pm/environments.py:305 activate_dependencies()`
   读不到已提交环境（`committed_venv()` → `None`，`:322`），转入
   `_require_own_dependencies()`（`:291`）：解释器不是 venv，且
   `sys.base_prefix` 落在 `store_root()`（`/vol1/@appdata/hermes/tools`）之内 →
   ```python
   raise RuntimeError("no dependency environment is committed for this install")  # :302
   ```
   实测确认三个前提同时成立：
   ```
   store_root   = /vol1/@appdata/hermes/tools
   state_dir    = /vol1/@appdata/hermes/installs/5fb99c8db7cd2f76  (存在)
   committed    = None
   ```

5. **`hermes_bootstrap.py:569` 把它印出来并退出**：
   ```python
   if command_argv(sys.argv[1:])[:1] != ["pm"]:
       print(f"hermes: {exc}; run `hermes pm repair`", file=sys.stderr)
       raise SystemExit(1)
   ```
   注意 `:568` 的 `!= ["pm"]` —— 这就是为什么**只有 `hermes pm *` 不受影响**，
   也正是报错文本让人误以为 `hermes pm repair` 能修好的原因（它确实能跑，只是
   在本布局下没有意义：PM 会去按 `uv.lock` 建一套完整依赖环境）。

6. **复现（修复前，真实命令）**：
   ```
   $ store_python -I -c "<runtime_command 的 bootstrap>" doctor
   hermes: no dependency environment is committed for this install; run `hermes pm repair`
   exit=1
   ```

---

## 三、受影响的功能

判据：**是否由 `runtime_command()`（即 `_launchers.py:44` 那条链）拉起**。

### A. 确认会失败（实测 exit 1，输出即上面那句话）

| 功能 | 代码位置 |
|---|---|
| dashboard「系统体检 doctor」 | `hermes_cli/web_routers/ops.py:548` → `_spawn_action:53` |
| dashboard「安全审计」 | `ops.py:554` |
| dashboard「备份 / 恢复备份」 | `ops.py:578` |
| dashboard「导入」 | `ops.py:608` |
| dashboard「curator 立即运行」 | `web_routers/status.py:667` |
| dashboard prompt-size / dump | `status.py:776,781` |
| dashboard「启动/停止/重启网关」 | `web_server_gateway.py:463`（包内 supervisor 只兜住了「退出后拉起」） |
| 网关服务单元 / launchd 里的启动命令 | `hermes_cli/gateway.py:930`、`gateway_launchd.py:212` |
| 网关 shutdown watcher | `gateway/run_shutdown.py:1471` |
| dashboard 自我重启 | `hermes_cli/main_dashboard.py:396` |
| **cron 的 `.py` 脚本** | `cron/scheduler_script.py:150-160`：`project_python()` 指向不存在的 `venv/bin/python` → `RuntimeError` |
| cron 外部 worker | `cron/worker_bootstrap.py:45` → `activate_dependencies` |
| 更新接管 / 更新前探测 | `hermes_cli/_update_takeover.py:47,75`、`update_cmd_validation.py:54` |

### B. 设计上不受影响

- **`hermes pm *`（含 `pm repair` / `pm status` / `pm doctor`）**：`hermes_bootstrap.py:568`
  明确放行，实测 exit 0。
- **`hermes update`**：本包 stamp 为 `updateMechanism: external`，走
  `update_channel.py:197` 的拒绝路径（提示走飞牛应用中心）。
- **服务主进程本身**：`cmd/main` 直接用 `${PY}` 启动，不经 `runtime_command`。
- **PM 工具链**：`pm.ensure()` 在工具已安装时直接返回，不碰 store Python；
  实测 `chromium / agent-browser / uv / tirith` 均 `ok`。

### C. 同一根因、但你未必撞到

TUI / 桌面端 spawn 的 `hermes` 子进程、以及任何第三方调用
`hermes_cli._launchers.runtime_command()` 的路径，都在同一条链上。

---

## 四、修复

### 已在本机实施（可回滚）

在 install state 里补上 PM 缺失的那一步登记：登记一个依赖环境，其
`site-packages` 与解释器都指向本包自带的 CPython。于是 `committed_venv()` 不再返回
`None`，`_require_own_dependencies()` 永不被触达。

```
/vol1/@appdata/hermes/installs/<install_key>/facts.json
  {"packages": {"venv": {"environment": "<…>/environments/fnos-package/venv",
                         "stamp": "<按 PM 同一算式实算>", "extras": []}}}
<…>/environments/fnos-package/venv/
  ├── pyvenv.cfg                    version = 3.14.7
  ├── bin/python        -> /vol1/@appcenter/hermes/runtime/python/bin/python3
  └── lib/python3.14/site-packages
                        -> /vol1/@appcenter/hermes/runtime/python/lib/python3.14/site-packages
```

为什么选这条而不是别的：

- **不写 `runtime/manifest.json`**。那条路会让 PM 进入 sealed payload 模式，
  `pm/runtime.py::_resident_runtime()` 随即要求 `runtime/pm-runtime/pm-runtime.json`
  与一个**在 payload 内**的 PM 运行时（含 packaging/tomli_w/truststore/ruamel.yaml），
  否则连 `pm.ensure("chromium")` 都会抛 `InstallError`。代价大、牵动面广。
- **不删 store Python**。删了 `resolve_store_python()` 会回落到 `sys.executable`（可行），
  但下一次 `pm.ensure()` 会把它重新下载回来，问题复发。本方案与 store Python 无关，
  它被重新下载也不影响。
- **`stamp` 如实计算**，所以 `venv_is_current()` 返回 `True`（dashboard 的
  memory-provider 页面会读它），PM 的自述是一致的，不是伪造状态。
- **不含 `.lease-managed` 标记**，`collect_generations()` 永不回收它；
  且它本身就是被选中的 generation，GC 会跳过。
- **幂等、约 0.3s**，每次服务启动重跑，覆盖解释器版本升级（3.14→3.15）与换卷后路径变化。
- 脚本内置拒绝：用 PM store Python 运行它会直接退出，避免把登记指向裸解释器
  （那样子进程不再报 pm repair，但会在第一个 import 上崩）。

### 交付物

```
/vol1/@appshare/hermes/workspace/fnos-pm-fix/
├── fnos-depenv.py      # 放到应用根目录（与 gateway-proxy.py 同级）
├── PATCH.md            # cmd/main 与 cmd/install_callback 的改动片段
├── REPORT.md           # 本文件
├── verify.txt          # 最终回归实测输出
└── battery.py          # 回归脚本
```

`cmd/main` 每次启动调用一次；`cmd/install_callback` 在 `chown` 之后调用一次（可选但建议）。

---

## 五、验证（真实退出码对照）

同一条命令、同一台机器，只切换「登记是否存在」：

| 命令（经真实 `runtime_command` → PM store Python） | 修复前 | 修复后 |
|---|---|---|
| `doctor` | exit 1 · `no dependency environment…` | exit 1 · 正常输出（1 是它自报的 2 条提示项） |
| `security audit` | exit 1 · 同上 | exit 1 · 正常输出（28 条漏洞发现，真实结果） |
| `prompt-size` | exit 1 · 同上 | exit 0 |
| `dump --help` | exit 1 · 同上 | exit 0 |
| `gateway status` | exit 1 · 同上 | exit 0 · `✓ Gateway is running` |
| `backup --help` | exit 1 · 同上 | exit 0 |
| `update --plan` | exit 1 · 同上 | exit 0 · 正常输出计划 |
| `pm status` | exit 0（本来就不受影响） | exit 0 |

回归同时确认未破坏：

```
is_runtime(): False | resident runtime: None
ensure(chromium) ok / ensure(agent-browser) ok / ensure(uv) ok / ensure(tirith) ok
committed_venv : <…>/environments/fnos-package/venv
venv_is_current: True
project_python : /vol1/@appcenter/hermes/runtime/python/bin/python3.14   ← cron .py 脚本已可用
site_packages  : <…>/environments/fnos-package/venv/lib/python3.14/site-packages
```

`doctor` 输出里也出现了一致的一行：
`✓ Runtime venv staged (<…>/environments/fnos-package/venv) (active in this process)`

### 回滚

```bash
rm -rf /vol1/@appdata/hermes/installs/5fb99c8db7cd2f76/environments
rm -f  /vol1/@appdata/hermes/installs/5fb99c8db7cd2f76/facts.json
```

（`facts.json` 在修复前不存在，所以这就是原始状态。）

---

## 六、顺带发现（与本次故障无关，建议打包时一并处理）

1. **包内源码树带着 `.git`**：`git status` 显示 16899 个改动，`hermes update --plan`
   因此把安装类型报成 `Install: git (v0.21.4 @ da1a5834)`。虽然
   `updateMechanism: external` 仍会拒绝自更新，但这个标签会误导排查者，也显著增大包体。
   上游 sealed payload 用 `git archive` 导出（`scripts/bundles/payload.py::snapshot`），不含 `.git`。
2. **`~/.local/bin/hermes` 软链缺失**（`doctor` 的第 1 条提示）：`_launchers.expose_cli()`
   对 `updateMechanism == "external"` 的安装直接 `skipped: externally-owned`，所以不会
   自动发布 CLI 入口。若希望在 shell 里直接敲 `hermes`，需要包内自己发一个转发脚本。
3. **可选加固**：若不想让用户误触发 PM 重建整套依赖环境（会覆盖本次登记），可在
   `config.yaml` 设 `security.allow_lazy_installs: false`。默认值 `true` 时，
   `pm.ensure()` 仍会按需下载工具（chromium/agent-browser 等）——那是本包需要的，别关。

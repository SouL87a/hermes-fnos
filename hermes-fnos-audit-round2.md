# fnOS Hermes 打包部署 · 第二轮审计报告(除已修问题外)

- 日期:2026-10-02
- 实例:`hermes`(应用根 `/vol1/@appcenter/hermes`,数据 `/vol1/@appdata/hermes`)
- 版本:`v0.21.4+canary.20261001T070239Z`(`da1a5834`,shallow clone)
- 本轮范围:已修 4 层(WS Origin / 资源 base / immutable 缓存 / basename 竞态)之外的新发现

> 所有结论均附实测命令输出。**未对生产做任何写操作**;唯一的本地验证是临时调试端口(已关闭)。

---

## 总览

| # | 级别 | 问题 | 影响 |
|---|---|---|---|
| 1 | **P0** | 在线更新会丢失 `/app/hermes` 前端前缀 | 点「更新 Hermes」后 lazy 路由黑屏 |
| 2 | **P1** | 更新端点的管理员校验可伪造(`X-Trim-Isadmin`) | 本机任意进程可触发更新 |
| 3 | **P1** | Dashboard 无鉴权 + session token 明文注入 | 任何能连 socket 者获得 hermes shell |
| 4 | **P2** | `.env` 第 4 行语法错误 | 每分钟 WARNING,该行静默失效 |
| 5 | **P2** | 缺少 `X-Forwarded-Host` / `X-Forwarded-Proto` | 启用 dashboard auth 后回调 URL 会错 |
| 6 | **P2** | PM 依赖环境未提交 | `hermes pm repair` 报错,PM 相关命令不可用 |
| 7 | **P3** | gateway 每次都非零码退出 | 从未优雅退出,重启链不干净 |
| 8 | **P3** | 所有 HTTP 请求强制 `Connection: close` | 首屏 10+ 次建连,无 keep-alive |
| 9 | **P3** | xterm CSS 靠服务端兜底改写 | 兜底失效则终端样式 404 |
| 10 | 外部 | 上游 LLM 网关 503 | agent 调用重试(非本包问题) |

---

## 1)【P0】在线更新会丢失前端前缀 → 更新后黑屏

### 现象
当前 `web_dist` 的资源路径带 `/app/hermes/` 前缀,但**源码树里没有任何地方设置这个前缀**。

### 证据

**(a) 打包产物的 base 是 patch 出来的**
```
$ grep -oE 'function\(e\)\{return`/[a-zA-Z/_-]*`\+e\}' react-vendor-*.js
react-vendor-BS8QpGW_.js : function(e){return`/app/hermes/`+e}
```
这就是 Vite 的 modulepreload/base helper —— 它的值被硬编码成 `/app/hermes/`。

**(b) 但上游构建链里没有 base**
```
$ grep -n "base" web/vite.config.ts          → 只有注释,无 base 配置
$ grep -n "base" scripts/build/web.mjs       → 无
$ grep -rnE "--base|VITE_BASE|HERMES_WEB_BASE" scripts/ web/ package.json → 零命中
```
`web/package.json` 的 build 脚本是 `node ../scripts/build/web.mjs`,该脚本调用
`build({ root, configFile, publicDir, build: {...} })` —— **不传 `base`**,Vite 默认 `"/"`。

**(c) 打包方也没改源码文件**
```
$ git diff -- web/vite.config.ts
old mode 100644
new mode 100755          ← 只有权限位变化,内容与 HEAD 完全一致
$ wc -c web/vite.config.ts → 5916 ;  git show HEAD:web/vite.config.ts | wc -c → 5916
```
结论:前缀是**打包仓库在构建后对产物做的后处理**,不在源码树里。

**(d) 更新脚本只做「构建 + 复制」,没有后处理**
```python
# hermes-update.py :: rebuild_web()
run([npm, "install", "--no-audit", "--no-fund", "--workspace", "web"], cwd=SRC)
run([npm, "run", "build", "--workspace", "web"], cwd=SRC)
built = SRC / "hermes_cli" / "web_dist"
shutil.copytree(built, WEB_DIST)      # ← 直接覆盖,无前缀化
```

### 影响
点 dashboard 里的「更新 Hermes」后,新 `web_dist` 的 base 回到 `"/"`:

- `index.html` 里的 `/assets/...` 会被服务端 `mount_spa` 兜底改写(`web_server_dashboard.py:174-178`),所以**入口脚本能加载、外壳能渲染**;
- 但 **JS 运行时算出的 lazy chunk 路径**用的是 base helper(`"/"`),服务端改不到 →
  请求 `/assets/ChatPage-*.js`(无前缀)→ **404** → 每个懒加载路由黑屏。

这正是之前修好的「layer 2」问题,只是这次由更新动作自己引入。而且 `--skip-build` 启动的
dashboard 进程不会自愈,需要重新打包或手工恢复前缀。

### 建议
在 `hermes-update.py::rebuild_web()` 的 `copytree` 之前加一段与打包仓库**等价**的后处理:

1. 改写 `index.html` 与所有 `assets/*.js` 里的 `"/assets/` → `"/app/hermes/assets/`(含 `` `/assets/ `` 模板形式);
2. 改写 base helper:`function(e){return\`/\`+e}` → `function(e){return\`/app/hermes/\`+e}`(先 `assert count==1` 再替换);
3. 替换后用 `curl` 或文本断言自检,失败则回滚。

**更好的做法**:构建时直接注入 base —— 但 `web.mjs` 属上游文件,`git reset --hard` 会覆盖它,
所以注入点必须放在 `hermes-update.py`(打包方自有文件)里,或由打包仓库提供一份可复用的
后处理脚本,两处共用同一份逻辑,避免漂移。

> 注:本条是**代码路径推断 + 产物对照**,未实机跑一次完整 `npm install && build`
> (源码树无 `node_modules`,下载数百 MB)。建议打包方在 CI 里跑一次构建并断言产物 base。

---

## 2)【P1】更新端点的管理员校验可伪造

### 现象
`gateway-proxy.py::_is_admin()` 只检查请求头是否存在,不校验来源或签名:
```python
def _is_admin(headers) -> bool:
    for k, v in headers:
        if k.lower() == "x-trim-isadmin":
            return v.strip().lower() in ("1", "true", "yes")
    return False
```

### 实测
```
$ curl --unix-socket /vol1/@appcenter/hermes/hermes.sock \
       http://localhost/app/hermes/__hermes/update/status
  status: 403

$ curl --unix-socket ... -H "X-Trim-Isadmin: 1" .../__hermes/update/status
  status: 200        ← 只加一个头就通过
```

### 影响范围(分两层)

- **本机层(已确认)**:任何能连到 `hermes.sock` 的进程都能伪造该头,触发
  `hermes-update.py apply`(git fetch + `reset --hard` + pip 重装)。socket 是 `0666`。
  实际横向面受 `/vol1` 权限(`user::--- group::--- other::---`)限制,但仍属弱设置。
- **外部层(未验证)**:经 fnOS 统一网关访问时,网关自身先做了 token 校验
  (实测无 token → 返回 `invalid token`),所以裸伪造被挡。但**网关是否剥离客户端自带的
  `X-Trim-*` 头尚未确认** —— `gateway-proxy.py` 明确剔除了 `X-Forwarded-*`,却**没有**剔除
  `X-Trim-*`。若网关只追加、不剥离,则任何已登录 fnOS 用户都能伪造管理员身份触发更新。

### 建议
1. 打包方确认 fnOS 网关注入 `X-Trim-*` 时是否**先剥离客户端的同名头**;若否,应在
   `gateway-proxy.py` 里无条件剔除客户端传入的 `x-trim-*`,只信任网关注入的。
2. `apply` 动作增加二次确认(例如要求一次性 nonce,或仅在交互式确认后放行)。
3. socket 权限从 `0666` 收到 `0660`(网关与应用同组即可)。

---

## 3)【P1】Dashboard 无鉴权 + session token 明文注入

### 证据
```
$ ss -lntp | grep hermes
LISTEN 127.0.0.1:9119    ← 仅回环(正确)
LISTEN 127.0.0.1:18642   ← 仅回环(正确)

$ curl -s --unix-socket .../hermes.sock http://localhost/app/hermes/ | grep SESSION_TOKEN
window.__HERMES_SESSION_TOKEN__="f9LEuWHzyNOkK_...";window.__HERMES_AUTH_REQUIRED__=false;
```

`gateway-proxy.py` 的头部注释也自述了这一点:
> dashboard 绑回环时**不做 auth 门**,因此能连到本 socket 的本机进程即等价于拥有控制台权限(可执行命令)。

### 影响
任何能到达 socket 的请求 → 读到明文 token → 调用全部 `/api/*` → 通过 `/api/pty`
开一个 PTY 终端(等同 `hermes --tui`)→ **以 `hermes` 身份执行任意命令**。

叠加 `ui/config` 的 `"allUsers": true`:fnOS 上的**任何普通用户**都能在应用中心看到并打开
Hermes,登录网关后即获得 hermes 用户的 shell —— 这是一条真实的权限提升路径。

### 建议
1. `cmd/main` 启动 gateway-proxy 时设置 `HERMES_GATEWAY_REQUIRE_TRIM=1`(代码已支持,默认关闭)。
   注意:这只是**提高门槛**(要求带 `X-Trim-*`),不是认证 —— 恶意本机进程仍可自加该头,
   所以必须与第 2 条的「剔除客户端 X-Trim-*」一起做才有意义。
2. socket 改 `0660`,属主 `hermes:hermes`,只让网关进程可连。
3. 若威胁模型包含「本机不受信进程」,考虑给 dashboard 启用真实 auth(注意:配置
   `public_url` 会同时打开 OAuth 门禁,需评估)。

---

## 4)【P2】`.env` 第 4 行语法错误(每分钟刷日志)

### 证据
```
$ tail errors.log
2026-10-02 13:57:04,544 WARNING dotenv.main: python-dotenv could not parse statement starting at line 4
```
(每分钟一条,来自 cron ticker 的 `_reload_dotenv_and_publish_delivery_target`)

行形态检查(未输出内容):
```
行1: 以#开头=True  ← 正常注释
行2: 以#开头=True  ← 正常注释
行4: 以#开头=False 含中文=True 含空格=True 含等号=False 长度=33
```

### 影响
第 4 行是一句**漏了 `#` 的中文说明文字**。功能上无影响(该行本就不该生效),
但每分钟一条 WARNING 会持续污染 `errors.log`,掩盖真正的告警。若该行本意是设置变量,
则会**静默失效** —— 建议人工确认一次。

### 建议
在 `.env` 第 4 行行首补 `#`。

---

## 5)【P2】缺少 `X-Forwarded-Host` / `X-Forwarded-Proto`

### 证据
`gateway-proxy.py` 会剔除客户端的这三个头,但只补回 Prefix:
```python
if lk in ("x-forwarded-prefix", "x-forwarded-host", "x-forwarded-proto"):
    continue
...
if PREFIX:
    out_lines.append(f"X-Forwarded-Prefix: {PREFIX}")   # ← 只补了 prefix
```

上游读这些头的地方:
```
hermes_cli/dashboard_auth/cookies.py:221   # cookie 的 Secure 标志
hermes_cli/dashboard_auth/routes.py:72     # url_for 生成 OAuth 回调
hermes_cli/web_server.py:1240              # X-Forwarded-Proto → Secure
```

### 影响
当前 dashboard 不做 auth 门,所以影响有限。**一旦启用 dashboard auth(OAuth)**,回调 URL 会
按 `http://127.0.0.1:9119` 生成,浏览器无法完成回调 → 登录死循环。属于「将来会咬人」的隐患。

### 建议
在代理里一并注入真实的 `X-Forwarded-Host`(取客户端原始 `Host`,但需与 fnOS 网关的信任边界
对齐)与 `X-Forwarded-Proto: https`。

---

## 6)【P2】PM 依赖环境未提交

### 证据
```
$ tail gateway-restart.log
=== gateway-restart started 2026-10-02 13:34:26 ===
hermes: no dependency environment is committed for this install; run `hermes pm repair`
```
每次 gateway 启动都会打印,历史 5 次重启均如此。

### 影响
本包刻意不用 venv(自带 CPython + 预装 site-packages),因此 PM 认为「没有已提交的依赖环境」。
运行时不受影响,但任何走 PM 的命令(`hermes update`、`hermes pm ...`、部分依赖相关路径)都会
报错或走错分支。这也正是打包方要自己实现 `hermes-update.py` 的原因,但**代价是这两条更新
链路长期分叉** —— 与第 1 条同源。

### 建议
至少让 `cmd/main` 在启动时把这个警告收敛成一次性提示,避免每次重启都进日志。

---

## 7)【P3】gateway 每次都是非零码退出

### 证据
```
$ tail gateway-exit-diag.log
{"tag": "asyncio.run.returned", "pid": 622616, "success": false}
{"tag": "gateway.exit_nonzero", "pid": 622616}
{"tag": "asyncio.run.returned", "pid": 707870, "success": false}
{"tag": "gateway.exit_nonzero", "pid": 707870}
... (5 次重启,全部 success=false)
```

### 影响
每次停止都走异常路径而非优雅退出。功能上被 fnOS 的重启机制兜住,但会让诊断日志长期
显示失败,且无法区分「正常重启」与「真崩溃」。

### 建议
`cmd/main` 的 stop 路径改为先发 SIGUSR1/SIGTERM 并等待 drain,超时才升级到 SIGKILL。

---

## 8)【P3】所有 HTTP 请求强制 `Connection: close`

### 证据
```python
if not is_upgrade:
    out_lines.append("Connection: close")
```

### 影响
首屏会并发 10+ 个资源/接口请求,每个都新建 TCP 连接(无 keep-alive)。在 NAS 上不是致命问题,
但会放大首屏延迟,也让「请求数」看起来比实际高。

### 建议
对非升级请求保留上游的 keep-alive 语义(不要强制 close),或至少不要覆盖客户端/上游的
`Connection` 头。

---

## 9)【P3】xterm CSS 依赖服务端兜底改写

### 证据
```
$ grep -oE '(href|src)="[^"]+"' web_dist/index.html
...
href="/app/hermes/assets/index-snEIC6gV.css"
href="/assets/xterm-BrP-ENHg.css"        ← 唯一没有前缀的一行
```
服务端 `mount_spa` 的兜底改写救了它:
```python
for attr in ('href="/assets/', 'src="/assets/', 'href="/favicon.ico"', ...):
    html = html.replace(attr, attr.replace('"/', f'"{prefix}/', 1))
```
(通过代理取到的 HTML 里这一行确实已带前缀。)

### 影响
这一行是打包后处理的漏网之鱼,靠服务端兜底才没 404。若将来构建产物出现更多无前缀引用
(例如新 chunk),而服务端改写列表没覆盖,就会静默 404。**JS 内部完全不受这层保护** ——
与第 1 条是同一个根因面。

### 建议
打包后处理里改用「所有以 `/` 开头的资源路径统一前缀化」的规则,而不是逐条列举。

---

## 10) 外部:上游 LLM 网关 503

```
openai.InternalServerError: Error code: 503 -
{'error': {'code': 'no_healthy_account',
           'message': 'all accounts are temporarily unavailable, please retry later'}}
```
`http://192.168.68.68:7864/v1` 账户池无健康账户。非本包问题,但会让 agent 反复重试,
值得留意该上游服务的容量。

---

## 与「重新打包会解决」的关系

- 你判断正确:**第 4 层(basename 入口竞态)确实会在重新打包时被修掉**,前提是打包方
  把入口 URL 改成带路径的形式,或修掉 `ProfileProvider` 的相对导航。
- 但要注意:**第 1 条(P0)恰恰是「重新打包」的反面** —— 它只在**不重新打包、走在线更新**
  时触发。所以两条路要一起考虑:
  - 若以后只走打包更新 → 需确保打包流程覆盖 `web_dist`(会,但会覆盖用户数据?不会,web_dist 独立);
  - 若走 dashboard 的「更新 Hermes」按钮 → **必须先修第 1 条**,否则更新即黑屏。

---

## 建议的优先级

1. **修第 1 条**(在线更新的前缀丢失)—— 这是唯一一条「用户一个点击就自伤」的问题;
2. **确认第 2 条的外部可达性**(网关是否剥离客户端 `X-Trim-*`)—— 决定是否需要紧急处理;
3. 第 3 条:打开 `HERMES_GATEWAY_REQUIRE_TRIM=1` + socket 收权限;
4. 第 4 条:`.env` 第 4 行补 `#`(一行改动);
5. 其余按 P2/P3 排期。

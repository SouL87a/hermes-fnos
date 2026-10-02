# Dashboard CHAT 页 TUI 终端顶部出现乱码 — 根因与打包修复方案

- 发现时间：2026-10-02
- 影响版本：Hermes v0.21.4（fnOS 打包版，`/vol1/@appcenter/hermes`）
- 影响面：`hermes dashboard` → **CHAT** 页（内嵌 `hermes --tui`）的终端渲染
- 结论：**xterm 的 CSS chunk 被当成 JS 预加载，从未生效**。触发条件是资源 URL 带 `?v=2` 查询串。

---

## TL;DR（给打包流程）

**问题**：vite 把 xterm 的 CSS 拆成懒加载 chunk，由 JS 的 `__vitePreload` 动态建 `<link>`；该 helper 用 `url.endsWith(".css")` 判断是否当样式表加载。资源 URL 一旦带查询串（如统一追加的 `?v=2`），判断失败 → link 变成 `rel="modulepreload" as="script"` → **只预取、不应用** → xterm.css 从未生效 → 终端顶部出现一行金色乱码。

**修法（任选；A + B 一起做最稳）**

| | 做法 | 位置 |
|---|---|---|
| **A** | 构建产物不要给资源 URL 加 `?v=N` | 打包流程里做 URL 版本注入的那一步（或干脆不做 —— 文件名已含 content hash） |
| **B** | 加一行 `import "@xterm/xterm/css/xterm.css";`，把 xterm 样式并进入口 CSS | `web/src/main.tsx`（上游源码，一行 patch） |
| **C** | 构建后跑 `fix-web-dist-xterm-css.sh <web_dist>`，在 index.html 里静态引入那个 CSS chunk | 打包收尾步骤（本目录已附脚本，幂等） |

**自检**（构建后）：

```bash
grep -o '[A-Za-z0-9_-]*\.css[^"]*' web_dist/assets/*.js | sort -u   # 不应出现带 ? 的 CSS 路径
grep -c 'xterm-helpers' web_dist/assets/index-*.css                 # 期望 ≥1（方案 B 之后）
```

---

## 1. 现象

dashboard → CHAT 页，内嵌终端面板**最顶部多出一行金色乱码**，形如：

```
))))))))))))))))))))))))))))))))❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯
```

或 `9999999999999999999999…`。**乱码内容随会话变化**（是终端里出现过的字符重复 32 次），底部状态栏下方一行提示被顶掉。

终端横幅、边框、三栏布局本身都正常 —— 问题只在终端内容层多出一行。

## 2. 根因（三层，逐层有实测证据）

### 2.1 页面缺少 xterm 的 CSS

`web_dist/assets/` 下有两个 CSS：

| 文件 | 含 `.xterm-helpers` | 引入方式 |
|---|---|---|
| `index-w1cyU43f.css` | **0** | index.html 静态 `<link rel="stylesheet">` ✅ 生效 |
| `xterm-BrP-ENHg.css` | **1** | 懒加载，由 JS 的 `__vitePreload` 动态创建 ❌ 未生效 |

浏览器实测：整页 `document.styleSheets` 里**没有任何一条** `.xterm-helpers` / `.xterm-char-measure-element` 规则。

### 2.2 该 CSS 被创建成了 `modulepreload` 而不是 `stylesheet`

拦截 `appendChild` 抓到的实际 link：

```json
{ "rel": "modulepreload",
  "href": "http://127.0.0.1:9119/app/hermes/assets/xterm-BrP-ENHg.css?v=2" }
```

`modulepreload` 只**预取**，不应用到文档 → CSS 从未生效。

### 2.3 判断失效的直接原因：`?v=2` + `endsWith('.css')`

构建产物 `react-vendor-BoVnYuL4.js` 里的 vite preload helper（已 minify）：

```js
var Yt = `modulepreload`,
    Xt = function(e){ return `/app/hermes/` + e },     // ← 构建 base 硬编码
    Qt = function(e,t,n){
      ...
      t = Xt(t, n);                 // 加 /app/hermes/ 前缀
      t = s(t);                     // import.meta.resolve / new URL(t, import.meta.url)
      let r = t.endsWith(`.css`);   // ★ 这里判断失败
      let i = document.createElement(`link`);
      i.rel = r ? `stylesheet` : Yt;      // ← 因为 r=false，rel 变成 modulepreload
      i.as  = r ? undefined : `script`;
      i.href = t;
      ...
      if (r) return new Promise(...)      // 只有真 CSS 才等待加载完成
    };
```

- 传入的 dep 是 `assets/xterm-BrP-ENHg.css?v=2`
- 拼完前缀/解析后是 `…/assets/xterm-BrP-ENHg.css?v=2`
- `"…css?v=2".endsWith(".css")` → **false**
- → `rel="modulepreload"` + `as="script"` → 浏览器当脚本预取，**样式永不应用**

### 2.4 `?v=2` 是后加的（有备份为证）

```
/vol1/@appcenter/hermes/runtime/web_dist.bak-20261001-233730/   ← 10-01 23:37 之前
```

| | 旧备份 | 当前 |
|---|---|---|
| index.html 里 `?v=2` 出现次数 | **0** | 全部资源都带 |
| JS 里 xterm css 引用 | `xterm-BrP-ENHg.css` | `xterm-BrP-ENHg.css?v=2` |

同目录还有 `gateway-proxy.py.bak-20261001-231024`、`/var/apps/hermes/cmd/main.bak-20261002-000700`，命名风格一致 → 10-01 23:37 有一次**对 web_dist 全部资源 URL 批量加 `?v=2`** 的操作（疑似为了强制刷新浏览器缓存）。

**注意：vite 产物文件名本身已带内容 hash（`index-LQnwqbgq.js`），缓存破坏本来就不需要 `?v=2`。**

### 2.5 为什么会"显示乱码"

xterm.js 的 `WidthCache` 会为**每个用到的字符**创建一个测量元素：

```html
<div class="xterm-width-cache-measure-container">
  <span class="xterm-char-measure-element">))))))))))))))))))))))))))))))))</span>
  <span class="xterm-char-measure-element">❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯</span>
</div>
```

正常情况下 xterm.css 会隐藏它们：

```css
.xterm .xterm-helpers { position: absolute; top: 0; z-index: 5; }
.xterm-char-measure-element { visibility: hidden; position: absolute; left: -9999em; }
```

CSS 没加载 → 这些元素以 `visibility: visible; position: static` 渲染在终端顶部，用终端主题色（金色）显示出来。**这就是那行乱码。**

### 2.6 已验证的因果链

手动注入 `<link rel="stylesheet" href="/assets/xterm-BrP-ENHg.css?v=2">` 后立刻：

```
BEFORE: measure-element { visibility: "visible", position: "static" }
AFTER : measure-element { visibility: "hidden",  position: "absolute" }
        xterm-helpers   { position: "absolute",  z-index: "5" }
```

截图确认：终端顶部乱码消失，横幅正常。**根因确认，修复方向确认。**

## 3. 次要问题：构建 base 硬编码为 `/app/hermes/`

`Xt = e => "/app/hermes/" + e` —— 打包构建时设了 `base: "/app/hermes/"`。

- **走飞牛网关**（`/app/hermes/…`）：前缀正确 ✅
- **直连 `127.0.0.1:9119`**：动态 URL 变成 `/app/hermes/assets/…` → 命中 SPA fallback，返回 index.html（HTTP 200 但内容是 HTML）❌

index.html 里的静态链接是 `/assets/…`（服务端按 `X-Forwarded-Prefix` 改写，无前缀时为空），所以出现「HTML 一套路径、JS 另一套路径」的不一致。网关场景下两者恰好都正确，**这不是本次乱码的原因**，但打包时值得留意。

---

## 4. 打包时的修复方案

### 方案 A（首选）：构建产物不要带 `?v=2`

**理由**：文件名已含 content hash，`?v=2` 冗余，且它是本次 bug 的唯一触发条件。

**做法**：
1. 在打包流程里找出给资源 URL 加 `?v=2` 的那一步（`grep -rn 'v=2\|VERSION' packaging/`），删掉；
2. 如果那一步是为了"强制刷新缓存"，改为依赖 vite 的 hash 文件名即可。

**打包后自检**：

```bash
cd <产物>/web_dist
grep -c '?v=' index.html                       # 期望 0
grep -o '[A-Za-z0-9_-]*\.css[^"]*' assets/*.js | sort -u   # 期望不带 ?v=
```

### 方案 B（更保险，推荐与 A 一起做）：把 xterm.css 提为入口 CSS

**理由**：即使将来有人再给 URL 加 query，也不会踩这个坑 —— 从"懒加载 CSS"变成"入口 CSS"，走 index.html 的静态 `<link rel="stylesheet">`。

**做法**（上游源码 patch，一行）：在 `web/src/main.tsx`（或任意入口模块）加：

```ts
import "@xterm/xterm/css/xterm.css";
```

`ChatPage.tsx` 里已有的同名 import 会被合并，`xterm-BrP-ENHg.css` 这个独立 chunk 消失，样式并入 `index-*.css`。

**打包后自检**：

```bash
ls web_dist/assets/*.css                       # 期望只剩 index-*.css
grep -c 'xterm-helpers' web_dist/assets/index-*.css   # 期望 ≥1
```

### 方案 C（不改源码，构建后处理）

构建脚本读 `web_dist/assets/xterm-*.css` 的实际文件名，往 `web_dist/index.html` 的 `<head>` 注入：

```html
<link rel="stylesheet" crossorigin href="/assets/xterm-<hash>.css?v=2">
```

- 直连：`/assets/…` 正确；
- 走网关：`gateway-proxy.py::rewrite_html_prefix` 会把 `href="/assets/` 改写成 `href="/app/hermes/assets/`，也正确。

⚠️ 注意：`rewrite_html_prefix` 只改写固定的几个前缀字符串，注入时必须用 `href="/assets/` 开头（不要写成绝对 URL 或带前缀）。

### 方案 D（不推荐）

改 minified 的 `react-vendor-*.js` 里的 `endsWith('.css')` 判断。脆弱、每次构建 hash 都变，不建议。

---

## 5. 临时热修（不重新打包时，立即可用）

在 `/vol1/@appcenter/hermes/runtime/web_dist/index.html` 的 `</head>` 前加一行：

```html
<link rel="stylesheet" crossorigin href="/assets/xterm-BrP-ENHg.css?v=2">
```

- 直连与网关场景都验证/推演通过（网关下由代理改写前缀）；
- 回滚 = 删掉这一行；
- ⚠️ `web_dist/` 属应用包文件，应用中心更新或 `hermes update` 会覆盖，需重打。

---

## 6. 配套脚本（已写好并测试）

`fix-web-dist-xterm-css.sh`（与本报告同目录）—— 打包流程的**收尾步骤**，幂等：

```bash
./fix-web-dist-xterm-css.sh <产物目录>/web_dist
# ✓ 已注入: xterm-BrP-ENHg.css?v=2
# ✓ 自检通过:index.html 已引用含 xterm 规则的 CSS
```

它做的事：找到 `assets/xterm-*.css`，在 `index.html` 的 `</head>` 前插入
`<link rel="stylesheet" crossorigin href="/assets/<name><沿用主 CSS 的 ?v=N>">`，
自动备份原 index.html，重复运行会跳过。

- 已在 `web_dist` 的临时副本上验证：注入 → 自检通过 → 二次运行幂等 → diff 仅新增一行；
- 已确认注入后浏览器里 `.xterm-char-measure-element` 由 `visible` 变 `hidden`，乱码消失；
- 若将来 xterm CSS 被并入入口 CSS（方案 B），脚本检测不到独立 chunk 会直接跳过。

---

## 7. 复现与验证命令

```bash
W=/vol1/@appcenter/hermes/runtime/web_dist

# 1. 两个 CSS 的内容差异（根因）
grep -c 'xterm-helpers' $W/assets/index-*.css     # 0  ← 主 CSS 里没有 xterm 规则
grep -c 'xterm-helpers' $W/assets/xterm-*.css     # 1  ← xterm 规则在这个懒加载 chunk 里

# 2. JS 里的 CSS 引用形式（触发条件）
grep -o 'xterm-[A-Za-z0-9_-]*\.css[^"]*' $W/assets/*.js | sort -u
#   assets/xterm-BrP-ENHg.css?v=2   ← 带 query，就是它导致判断失败

# 3. preload helper（机制）
grep -o 'let r=t.endsWith(`.css`)[^;]*;' $W/assets/react-vendor-*.js

# 4. base 硬编码
grep -o 'Xt=function(e){return`/app/hermes/`+e}' $W/assets/react-vendor-*.js

# 5. 对比备份（?v=2 是后加的）
diff $W.bak-20261001-233730/index.html $W/index.html | head
```

浏览器侧验证（打开 dashboard → CHAT）：

```js
// 应为 "stylesheet" 且 sheet 存在；若为 "modulepreload" 即复现
[...document.querySelectorAll('link')].filter(l => l.href.includes('xterm'))
// 应为 "hidden"；若为 "visible" 即复现
getComputedStyle(document.querySelector('.xterm-char-measure-element')).visibility
```

---

## 8. 待确认

1. **`?v=2` 是打包流程加的，还是部署后在本机改的？** 备份显示是 10-01 23:37 在**本机 web_dist 上**批量加的；若打包流程里也有这一步，方案 A 就直接落在打包脚本里。
2. 打包时 `base: "/app/hermes/"` 是刻意设置（配合网关前缀）—— 建议保留，但需要知道它会让直连场景的资源路径带前缀（走 SPA fallback 返回 HTML）。

---

## 附：关键时间线

| 时间 | 事件 |
|---|---|
| 10-01 22:46 | 应用包解包，web_dist 就位（此时 URL **不带** `?v=2`） |
| 10-01 23:10 | `gateway-proxy.py` 被修改（留下 .bak） |
| 10-01 23:24–23:37 | web_dist 被改动，全部资源 URL 加上 `?v=2`（留下 .bak）→ **引入本 bug** |
| 10-02 00:07 | `/var/apps/hermes/cmd/main` 被修改（补 gateway 拉起逻辑，留下 .bak） |
| 10-02 10:08 | 复现、定位、验证修复 |

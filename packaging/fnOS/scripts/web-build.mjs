// Hermes 前端构建 —— 直接调 vite，并注入 fnOS 网关前缀（base）。
//
// 为什么不用上游的构建入口：
//   · canary/main 走 scripts/build/web.mjs（自定义、带图标/freshness 机制）；
//   · stable（如 v2026.9.24）根本没有 scripts/build/，web 的 build 就是
//     `tsc -b && vite build`，而 tsc 全量类型检查很慢且对产物无影响。
//   为了让本包对两种上游布局都成立，这里直接 import vite 并调用 build()，
//   只依赖 vite 本身与 web/vite.config.ts。
//
// 由 build.sh 复制到源码树根后执行（node .hermes-web-build.mjs）。
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { createRequire } from "node:module"

const source = process.cwd()
const root = path.join(source, "web")
const out = path.join(source, "hermes_cli", "web_dist")
const BASE = process.env.HERMES_WEB_BASE || "/app/hermes/"

if (!existsSync(path.join(root, "package.json"))) {
  throw new Error(`不是 web 工作区：${root}`)
}

// 从 web 工作区解析 vite（npm workspaces 会提升到根 node_modules，两种都试）
function resolveVite() {
  for (const base of [root, source]) {
    try {
      const req = createRequire(path.join(base, "noop.js"))
      return req.resolve("vite")
    } catch { /* 继续试下一个 */ }
  }
  throw new Error("找不到 vite（请先 npm install --workspace web）")
}

// public 目录：stable 下 web/public 已有 favicon/fonts，直接用它
const publicDir = path.join(root, "public")
if (!existsSync(publicDir)) mkdirSync(publicDir, { recursive: true })

const vitePath = resolveVite()
const { build } = await import(pathToFileURL(vitePath).href)

await build({
  root,
  configFile: path.join(root, "vite.config.ts"),
  // configLoader: 'bundle'（vite 默认）—— stable 的 vite.config.ts 里既有
  // require/__dirname（CJS 风格）又有顶层 await，'runner' 会报
  // ERR_AMBIGUOUS_MODULE_SYNTAX；'bundle' 先把配置打包再执行，两种都吃。
  configLoader: "bundle",
  publicDir,
  // ⚠ 关键：注入 fnOS 网关前缀。
  // 上游 vite.config.ts 没配 base → 产物里 base 编译成 "/"，
  // JS 里的懒加载 chunk 会请求 /assets/...（站点根）→ 404 → 黑屏。
  base: BASE,
  build: {
    outDir: out,
    emptyOutDir: true,
  },
})

if (!existsSync(path.join(out, "index.html"))) {
  throw new Error("Vite 未产出 index.html")
}

console.log(`[web-build] vite 构建完成，base=${BASE}`)

// ── 修复：xterm.css 静态引入 index.html ──────────────────────
// 上游 codeSplitting 把 @xterm/* 拆成独立 chunk，其 CSS 由 __vitePreload 动态加载；
// 该 helper 用 endsWith('.css') 判断，URL 带 query 即失效 → rel=modulepreload
// → 样式不应用 → 终端顶部一行乱码。静态引入可绕开这条脆弱路径。
const assetsDir = path.join(out, "assets")
const indexPath = path.join(out, "index.html")
let html = readFileSync(indexPath, "utf8")

if (!html.includes("hermes-xterm-css-fix")) {
  const xtermCssFiles = existsSync(assetsDir)
    ? readdirSync(assetsDir).filter(f => /^xterm-.*\.css$/.test(f))
    : []
  if (xtermCssFiles.length > 0) {
    const base = BASE.replace(/\/+$/, "")
    const tags = xtermCssFiles
      .map(f => `<link rel="stylesheet" crossorigin href="${base}/assets/${f}" data-hermes-xterm-css-fix>`)
      .join("\n    ")
    html = html.replace("</head>", `  ${tags}\n  </head>`)
    writeFileSync(indexPath, html, "utf8")
    console.log(`[web-build] xterm CSS 已静态引入: ${xtermCssFiles.join(", ")}`)
  }
}

// 自检
if (html.includes("?v=")) {
  console.warn("[web-build] ⚠ index.html 里出现 ?v= 查询串（会破坏 CSS 懒加载判断）")
}
if (!html.includes(`${BASE.replace(/\/+$/, "")}/assets/`)) {
  throw new Error(`产物未带 ${BASE} 前缀 —— base 注入失败，装上去会黑屏`)
}

console.log("WEB_DIST_OK")

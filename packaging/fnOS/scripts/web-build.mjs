// Hermes 前端构建 —— 跳过 TypeScript 全量类型检查，只跑 vite 打包。
//
// 为什么需要这个：上游 scripts/build/web.mjs 在打包前会跑一遍 tsc solution
// builder 做**全量类型检查**。该检查只做校验、不产出任何文件，对 web_dist 无
// 影响；但大型 React 项目上极慢（实测十几分钟，且进程内跑、无输出、易被误判卡死）。
// 这里复用上游的 frontend-common / freshness 辅助函数，保证产物布局与上游一致。
//
// 由 build.sh 复制到源码树根后执行（node .hermes-web-build.mjs）。
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { productOutput, workspaceTool, withProduct } from './scripts/build/frontend-common.mjs'
import { recordProduct, buildInputs } from './scripts/build/freshness.mjs'

const source = process.cwd()
const out = path.join(source, 'hermes_cli/web_dist')

const publicIcons = path.join(source, 'web/public')
if (!existsSync(path.join(publicIcons, 'favicon.ico'))) {
  throw new Error(`缺少图标：${path.join(publicIcons, 'favicon.ico')}`)
}

const root = path.join(source, 'web')
const inputs = buildInputs(source, 'web', { icons: publicIcons })
const { build } = await import(pathToFileURL(workspaceTool(source, 'web', 'vite')).href)

await withProduct(out, async (productDir, scratchDir) => {
  const publicDir = path.join(scratchDir, 'public')
  mkdirSync(publicDir, { recursive: true })
  if (existsSync(path.join(root, 'public'))) {
    cpSync(path.join(root, 'public'), publicDir, { recursive: true })
  }
  cpSync(publicIcons, publicDir, { recursive: true })
  await build({
    root,
    configFile: path.join(root, 'vite.config.ts'),
    configLoader: 'runner',
    cacheDir: path.join(scratchDir, 'vite-cache'),
    publicDir,
    // ⚠ 关键：设置 Vite 的 base 为 fnOS 网关前缀。
    //
    // 上游 vite.config.ts 没有配 base，产物里 base 被编译成 "/"：
    //   react-vendor 里  Xt = function(e){ return `/` + e }
    //   index-*.js 里    import(`./ChatPage-xxx.js`)  ← 相对路径，靠 Xt 拼接
    // 于是懒加载路由（对话 / SYSTEM）请求 /assets/...（站点根）→ 404 → 黑屏。
    //
    // 注意：路由与 API 走的是运行时 window.__HERMES_BASE_PATH__（由服务端依据
    // X-Forwarded-Prefix 注入），那部分是好的；坏的只有静态资源 base，
    // 而它只能在**编译时**确定 —— 所以必须在这里传。
    base: process.env.HERMES_WEB_BASE || '/app/hermes/',
    build: { outDir: productDir, emptyOutDir: true },
  })
  if (!existsSync(path.join(productDir, 'index.html'))) {
    throw new Error('Web 构建未产出 index.html')
  }
  recordProduct({ source, product: 'web', out: productDir, inputs })
}, { source })

// ── 修复：xterm.css 静态引入 index.html ──────────────────────
//
// 背景：ChatPage / HermesConsoleModal 里 `import "@xterm/xterm/css/xterm.css"`，
// 而上游 vite.config.ts 有一条 codeSplitting 规则把 @xterm/* 强制拆成独立
// `xterm` chunk。于是这份 CSS 由 JS 的 __vitePreload 动态建 <link>，而该 helper
// 用 `url.endsWith(".css")` 判断是否按样式表加载 —— URL 一旦带查询串
// （如缓存破坏用的 ?v=2），判断失败 → link 变成 rel="modulepreload" → 只预取
// 不应用 → xterm.css 从未生效 → 终端顶部出现一行乱码（xterm 的字符测量元素
// 未被 CSS 隐藏）。
//
// 这里在 index.html 里**静态**引入该 chunk（方案 C）：走浏览器原生的
// <link rel="stylesheet">，彻底绕开 __vitePreload 那条脆弱路径。
// 幂等：已存在则跳过。注意 href 用 "/assets/" 开头 —— gateway-proxy 的
// rewrite_html_prefix 会按前缀改写成 "/app/hermes/assets/"。
const assetsDir = path.join(out, 'assets')
const indexPath = path.join(out, 'index.html')
let html = readFileSync(indexPath, 'utf8')

if (!html.includes('hermes-xterm-css-fix')) {
  const xtermCssFiles = existsSync(assetsDir)
    ? readdirSync(assetsDir).filter(f => /^xterm-.*\.css$/.test(f))
    : []
  if (xtermCssFiles.length > 0) {
    const tags = xtermCssFiles
      .map(f => `<link rel="stylesheet" crossorigin href="/assets/${f}" data-hermes-xterm-css-fix>`)
      .join('\n    ')
    html = html.replace('</head>', `  ${tags}\n  </head>`)
    writeFileSync(indexPath, html)
    console.log(`[web-build] xterm CSS 已静态引入 index.html: ${xtermCssFiles.join(', ')}`)
  } else {
    console.log('[web-build] 无独立 xterm CSS chunk（已并入入口或不存在）')
  }
}

// 自检：资源 URL 不应带查询串（否则 __vitePreload 的 .css 判断会失效）
if (html.includes('?v=')) {
  console.warn('[web-build] ⚠ index.html 里出现 ?v= 查询串（会破坏 CSS 懒加载判断）')
}

console.log('WEB_DIST_OK')

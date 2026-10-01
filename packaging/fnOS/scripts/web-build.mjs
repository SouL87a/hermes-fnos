// Hermes 前端构建 —— 跳过 TypeScript 全量类型检查，只跑 vite 打包。
//
// 为什么需要这个：上游 scripts/build/web.mjs 在打包前会跑一遍 tsc solution
// builder 做**全量类型检查**。该检查只做校验、不产出任何文件，对 web_dist 无
// 影响；但大型 React 项目上极慢（实测十几分钟，且进程内跑、无输出、易被误判卡死）。
// 这里复用上游的 frontend-common / freshness 辅助函数，保证产物布局与上游一致。
//
// 由 build.sh 复制到源码树根后执行（node .hermes-web-build.mjs）。
import { cpSync, existsSync, mkdirSync } from 'node:fs'
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
    build: { outDir: productDir, emptyOutDir: true },
  })
  if (!existsSync(path.join(productDir, 'index.html'))) {
    throw new Error('Web 构建未产出 index.html')
  }
  recordProduct({ source, product: 'web', out: productDir, inputs })
}, { source })

console.log('WEB_DIST_OK')

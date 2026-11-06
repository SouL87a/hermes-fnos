#!/usr/bin/env bash
#
# 构建飞牛 fnOS 原生应用包（.fpk）—— Hermes Agent
# ===============================================
# 产物：packaging/fnOS/dist/hermes-<version>.fpk
#
# payload 不是上游的现成 runtime（上游只给安装脚本，靠 uv 现拉），而是本地装配：
#   1. python-build-standalone 的 CPython 3.14（可重定位、自带 SQLite 3.53.1，随包分发）
#   2. 依赖装进该 CPython 的 site-packages（构建时联网一次，运行期零联网）
#   3. 前端预构建（npm build → hermes_cli/web_dist）
#   4. 上游源码树（钉住 upstream.version 的提交）
#
# 用法：
#   bash packaging/fnOS/scripts/build.sh
#   bash packaging/fnOS/scripts/build.sh --src /path/to/hermes-agent   # 复用已有源码树
#   bash packaging/fnOS/scripts/build.sh --skip-web                    # 跳过前端构建（复用已有 web_dist）
#   HERMES_VERSION=0.2.0 bash packaging/fnOS/scripts/build.sh
#
# 前置：bash、curl、tar、python3（>=3.10，仅构建脚本自用）；前端构建需 node/npm。
#
# ⚠ fnpack 打 app.tgz 时会把权限拍平成 0666/0777（官方模板同款行为），
#   可执行位由 cmd/install_callback 在装机时补回。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "${HERE}/.." && pwd)"                 # packaging/fnOS
REPO="$(cd "${PKG_DIR}/../.." && pwd)"              # 仓库根
APP="hermes"

DIST="${PKG_DIR}/dist"
STAGE="${PKG_DIR}/.build-staging/${APP}"            # 交给 fnpack 的目录
APP_DIR="${STAGE}/app"                              # 应用内容树（会打成 app.tgz）
RT="${APP_DIR}/runtime"                             # python/ + hermes/ + web_dist/

# ── 参数 ─────────────────────────────────────────────────────
SRC_DIR_ARG=""
SKIP_WEB=0
PRESET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --src)      SRC_DIR_ARG="${2:-}"; shift 2 ;;
        --skip-web) SKIP_WEB=1; shift ;;
        --preset)   PRESET="${2:-}"; shift 2 ;;   # B = 预置 Python 压缩包 + wheelhouse
        -h|--help)  sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)          echo "未知参数：$1"; exit 1 ;;
    esac
done

# ── 工具定位 ─────────────────────────────────────────────────
if [ -z "${FNPACK:-}" ]; then
    if command -v fnpack > /dev/null 2>&1; then
        FNPACK="fnpack"
    elif [ -f "${REPO}/fnpack" ]; then
        FNPACK="${REPO}/fnpack"
    elif [ -f "${PKG_DIR}/fnpack" ]; then
        FNPACK="${PKG_DIR}/fnpack"
    else
        FNPACK=""
    fi
fi

### 路径转换：Windows 的 Git Bash 下需要 cygpath（传给原生 exe 的路径要转
### Windows 形式）；Linux/WSL 下 cygpath 不存在，原样返回即可。
winpath() { cygpath -w "$1" 2>/dev/null || echo "$1"; }

need() { command -v "$1" > /dev/null 2>&1 || { echo "✗ 缺少命令：$1"; exit 1; }; }
need curl; need tar; need git

### 平台提示：**必须在 Linux 上构建**（WSL 即可）。
### 原因：包里要分发 Linux 的 CPython 与 Linux 的 .so 依赖，Windows 无法执行
### 这些 ELF 二进制，无法完成依赖安装。WSL 与目标 fnOS 同属 Debian 系，最接近。
if [ "$(uname -s)" = "Darwin" ]; then
    echo "⚠ 在 macOS 上构建：目标 Linux 的 CPython 无法在本机执行，依赖安装会失败。"
    echo "  请改用 Linux 或 WSL 构建。"
fi

# ── 版本号 ───────────────────────────────────────────────────
# 覆盖顺序：HERMES_VERSION env > fnos.version > 上游 ref 推导。
#
# fnos.version 用于「同一上游版本的重打包」：上游仍是 v0.22.2，但我们修了
# 打包缺陷 → 写 0.22.2-1，让 fnOS 判定为升级（Debian 的 upstream-revision
# 规则，0.22.2-1 > 0.22.2），用户可直接覆盖安装而不必卸载。
#   fnos.version: 0.22.2-1  → fpk 版本 0.22.2-1
# 未提供 fnos.version 时跟随上游 tag（去掉 v 与 +canary 后缀，保留 -N）：
#   v0.22.2                        → 0.22.2
#   v0.22.2-1                      → 0.22.2-1
#   v0.21.4+canary.20261001T070239Z → 0.21.4
#   v2026.9.24                     → 2026.9.24
### ⚠ 两处 grep 都加 `|| true`：文件若只剩注释（无有效行），grep 返回 1，
### 在 `set -euo pipefail` 下会让整个脚本【静默退出且无任何输出】
### （实机踩过：清空 fnos.version 的值行后，CI 只报 exit code 1、无日志）。
UPSTREAM_REF_V="$(grep -vE '^\s*#|^\s*$' "${REPO}/upstream.version" 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
UP_VER=""
[ -n "${UPSTREAM_REF_V}" ] && UP_VER="$(printf '%s' "${UPSTREAM_REF_V}" | sed -E 's/^v//; s/\+.*$//')"
VERSION="${HERMES_VERSION:-}"
if [ -z "${VERSION}" ] && [ -f "${REPO}/fnos.version" ]; then
    _fv="$(grep -vE '^\s*#|^\s*$' "${REPO}/fnos.version" | head -n 1 | tr -d '[:space:]' || true)"
    if [ -n "${_fv}" ]; then
        if [ -z "${UP_VER}" ] || [ "${_fv%%-*}" = "${UP_VER}" ]; then
            VERSION="${_fv}"
            echo "[build] 使用 fnos.version 指定的打包版本：${VERSION}"
        else
            echo "[build] ⚠ fnos.version=${_fv} 与上游 ${UP_VER} 不一致，已忽略（请更新或清空 fnos.version）"
        fi
    fi
fi
[ -z "${VERSION}" ] && VERSION="${UP_VER}"
[ -z "${VERSION}" ] && VERSION="0.0.0"
echo "[build] 版本 ${VERSION}（跟随上游 ${UPSTREAM_REF_V:-?}）"

# ── 架构（首版 x86_64 单架构）───────────────────────────────
# fnOS 的 TRIM_SYS_ARCH 取值是 x86 / arm（manifest platform 同款口径）。
ARCH="${HERMES_ARCH:-x86_64}"
case "${ARCH}" in
    x86_64)  PBS_TRIPLE="x86_64-unknown-linux-gnu";  MANIFEST_PLATFORM="x86" ;;
    aarch64) PBS_TRIPLE="aarch64-unknown-linux-gnu"; MANIFEST_PLATFORM="arm" ;;
    *)       echo "✗ 不支持的架构：${ARCH}（用 x86_64 / aarch64）"; exit 1 ;;
esac
echo "[build] 架构 ${ARCH} (${PBS_TRIPLE})"

### 构建缓存（ripgrep 等可选组件；不再用于 CPython/依赖）
PBS_CACHE="${PKG_DIR}/.cache"
mkdir -p "${PBS_CACHE}"

# ── 上游源码树 ───────────────────────────────────────────────
if [ -n "${SRC_DIR_ARG}" ]; then
    SRC="${SRC_DIR_ARG}"
else
    SRC="${PKG_DIR}/.src/hermes-agent"
    if [ ! -d "${SRC}/hermes_cli" ]; then
        # upstream.version 可能带 # 注释行，取第一个非注释、非空行
        UPSTREAM="$(grep -vE '^\s*#|^\s*$' "${REPO}/upstream.version" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
        echo "[build] 克隆上游源码树（${UPSTREAM:-main}）…"
        rm -rf "${SRC}"
        mkdir -p "$(dirname "${SRC}")"
        # 浅克隆 tag：上游仓库很大，--depth 1 + 单分支能省几分钟
        if [ -n "${UPSTREAM}" ]; then
            git clone --depth 1 --branch "${UPSTREAM}" \
                https://github.com/NousResearch/hermes-agent.git "${SRC}" \
              || { echo "✗ 克隆 tag ${UPSTREAM} 失败，回退 main"; \
                   git clone --depth 1 https://github.com/NousResearch/hermes-agent.git "${SRC}"; }
        else
            git clone --depth 1 https://github.com/NousResearch/hermes-agent.git "${SRC}"
        fi
    fi
fi
[ -d "${SRC}/hermes_cli" ] || { echo "✗ 源码树无效：${SRC}"; exit 1; }
echo "[build] 源码树：${SRC} ($(cd "${SRC}" && git rev-parse --short HEAD 2>/dev/null || echo '?'))"

# ── 干净重建 ─────────────────────────────────────────────────
rm -rf "${STAGE}"
mkdir -p "${STAGE}" "${APP_DIR}" "${DIST}" "${RT}"

# ── 1. 运行期不由构建期提供 ────────────────────────────────
# 本包不再预置 CPython / 依赖 / 源码树 / .git。
# 这些由 cmd/install_callback 调 scripts/install-runtime.sh 在 NAS 上获取：
#   1. uv（锁定版本 + sha256）
#   2. git clone 源码 → <data>/src（保留 .git，支持 hermes update）
#   3. pm install（PM 下 Python、建真实 venv、装依赖）
# 这样得到的是上游原生的 venv，不需要任何补丁。
#
# 构建期仍需预构建前端（web_dist），因为不保证 NAS 上有 node/npm。

# ── 3. install-stamp.json（构建信息戳）─────────────────────
# 只记录版本来源；不再写 distribution/payload —— 源码在数据目录且带 .git，
# 上游 sealed_steward() 见到 .git 即返回 None，允许 hermes update。
# 写 distribution 反而可能让某些路径误判为"受管安装"而拒绝更新。
STAMP="${RT}/install-stamp.json"
STAMP_COMMIT="$("git" -C "${SRC}" rev-parse HEAD 2>/dev/null || echo '')"
STAMP_BRANCH="$("git" -C "${SRC}" branch --show-current 2>/dev/null || echo '')"
STAMP_DATE="$("git" -C "${SRC}" log -1 --format=%ct 2>/dev/null || echo '')"
[ -n "${STAMP_COMMIT}" ] || STAMP_COMMIT="$(printf '0%.0s' $(seq 1 40))"

STAMP_PY=""
for cand in python3 python; do
    command -v "${cand}" > /dev/null 2>&1 && { STAMP_PY="${cand}"; break; }
done
[ -n "${STAMP_PY}" ] || { echo "✗ 找不到 python 用于生成 install-stamp.json"; exit 1; }

"${STAMP_PY}" - "$(winpath "${STAMP}")" "${STAMP_COMMIT}" "${VERSION}" "${STAMP_BRANCH}" "${STAMP_DATE}" <<'PY'
import json, sys, datetime
out, commit, base, branch, cdate = sys.argv[1:6]
stamp = {
    "schemaVersion": 2,
    "commit": commit,
    "commitDate": int(cdate) if cdate.isdigit() else None,
    "branch": branch or None,
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "dirty": False,
    "source": "local",
    "baseVersion": base,
    "displayVersion": base,
    "distance": 0,
}
open(out, "w", encoding="utf-8").write(json.dumps(stamp, ensure_ascii=False, indent=2) + chr(10))
PY
[ -f "${STAMP}" ] || { echo "✗ install-stamp.json 生成失败"; exit 1; }
# 记录上游 ref，安装期 install-runtime.sh 要用它 clone 对应版本
echo "${UPSTREAM_REF_V:-v0.22.5}" > "${APP_DIR}/upstream-ref"

# ── 3b. 档位 B 预置（--preset B）────────────────────────────
# 在线版（默认）安装期要下 ~900 MB（uv 16M + 源码 60M + Python 73M + 依赖 venv）。
# 档位 B 把其中最大的两块打进 fpk：
#   · Python 压缩包（~73 MB）→ 安装期解压到 <data>/pythons，uv python find 直接命中
#   · wheelhouse（~50 MB）  → PM 解析后 uv 从本地装 wheel（仍需 git 做 universal 解析）
# 收益：安装期下载 900 MB → ~60 MB（只剩源码 clone，保留 .git 与 hermes update）
# 代价：fpk 4 MB → ~130 MB
if [ "${PRESET}" = "B" ]; then
    echo "[build] 档位 B：预置 Python 压缩包 + wheelhouse"
    PY_VERSION="${HERMES_PY_VERSION:-}"
    PBS_TAG="${HERMES_PBS_TAG:-}"
    if [ -z "${PY_VERSION}" ] || [ -z "${PBS_TAG}" ]; then
        # 与 PM 的锁定版本对齐：从源码树的 pm/lock.json 读（如 "3.14.9+20261021"）
        [ -n "${STAMP_PY}" ] || { echo "✗ 缺 python 用于解析 pm/lock.json"; exit 1; }
        LOCKED="$("${STAMP_PY}" -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
print(d['packages']['python']['version'])" "${SRC}/pm/lock.json" 2>/dev/null || true)"
        [ -n "${LOCKED}" ] || { echo "✗ 无法从 pm/lock.json 读 Python 版本"; exit 1; }
        PY_VERSION="${PY_VERSION:-${LOCKED%%+*}}"
        PBS_TAG="${PBS_TAG:-${LOCKED##*+}}"
    fi
    echo "[build]   预置 Python ${PY_VERSION}+${PBS_TAG}（与 pm/lock.json 对齐）"

    PBS_TGZ="${PBS_CACHE}/cpython-${PY_VERSION}-${PBS_TRIPLE}.tar.gz"
    if [ ! -f "${PBS_TGZ}" ]; then
        PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/cpython-${PY_VERSION}+${PBS_TAG}-${PBS_TRIPLE}-install_only.tar.gz"
        PBS_URL="${HERMES_GH_MIRROR:+${HERMES_GH_MIRROR}/}${PBS_URL}"
        echo "[build]   下载 PBS → ${PBS_URL}"
        curl -fL --retry 3 -o "${PBS_TGZ}.part" "${PBS_URL}" \
            && mv "${PBS_TGZ}.part" "${PBS_TGZ}" \
            || { rm -f "${PBS_TGZ}.part"; echo "✗ PBS 下载失败"; exit 1; }
    fi
    cp "${PBS_TGZ}" "${RT}/python.tar.gz"
    echo "[build]   python.tar.gz ✓ ($(du -h "${RT}/python.tar.gz" | cut -f1))"

    # wheelhouse：从源码树的 uv.lock 导出精确依赖再下载（与 PM 同一解析结果）
    echo "[build]   导出依赖清单…"
    "${STAMP_PY}" -c "import uv" 2>/dev/null || need uv
    UV_EXPORT=(export --frozen --no-hashes --no-dev --no-emit-project
               --extra web --extra messaging
               --extra mcp --extra computer-use --extra vercel
               --extra wake-openwakeword --extra uvloop)
    ( cd "${SRC}" && uv "${UV_EXPORT[@]}" -o "${RT}/requirements.lock" ) \
        || { echo "✗ uv export 失败"; exit 1; }
    echo "[build]   下载 wheelhouse（pip download，用构建机 python3 的 pip）…"
    # ⚠ uv 没有 `pip download` 子命令（实测 0.13.5：unrecognized subcommand）。
    #   用标准 pip download：构建机 python3 自带 pip，语义一致
    #   （-r 需求清单 → 下载 wheel 到目录）。指定 cp314/linux 平台，
    #   避免拉到源码包或其它平台的 wheel。
    # ⚠ --platform 必须枚举全部标签族：上游新 wheel 用 manylinux_2_28 等新标签，
    #   只给 manylinux2014 会漏掉它们 → 报 "No matching distribution"（实机 2026-11-05
    #   的 cbor2：PyPI 有 cp314+manylinux_2_28 wheel，但平台参数不含该标签族 → 失败）。
    #   一次报错就是失败（pip download 不会跳过单个包），所以宁可多列。
    # ⚠ 必须 --no-deps：requirements.lock 是 `uv export --frozen` 的产物，
    #   本身就是 uv.lock 解析完的【完整扁平依赖图】（逐包精确 pin），不需要
    #   也不应该再由 pip 重新解析。pip 一旦解析传递依赖就会撞上
    #   browser-harness 0.1.13 元数据里精确 pin 的 pillow==12.3.0，与清单中
    #   override 后的 13.0.0 直接冲突 → ResolutionImpossible（实机 2026-11-05）。
    #   uv 能把它们放一起靠的是 `[tool.uv] override-dependencies`，pip 没有
    #   等价语义：--constraint 只会【收窄】版本，无法覆盖依赖自己的 pin，
    #   反而制造死锁（pm/environment.py 安装期也是靠 `uv pip install
    #   --overrides` 把 lock 里的 overrides 加回来，见 pm/pip_check.py）。
    #   --no-deps 让 pip 退化成"按清单逐条下 wheel"，冲突不复存在，
    #   且产物与 uv.lock 一致（清单本来就从它导出）。
    PIP_ARGS=(download
        -r "${RT}/requirements.lock"
        -d "${RT}/wheelhouse"
        --no-deps
        --only-binary :all:
        --python-version 3.14
        --platform manylinux2014_x86_64
        --platform manylinux_2_17_x86_64
        --platform manylinux_2_28_x86_64
        --platform manylinux_2_34_x86_64
        --platform manylinux_2_35_x86_64
        --platform manylinux_2_36_x86_64
        --platform manylinux_2_39_x86_64
        --platform linux_x86_64
        --platform any
        --implementation cp
        --abi cp314
        --abi cp313
        --abi abi3
        --abi none)
    [ -n "${HERMES_PIP_INDEX:-}" ] && PIP_ARGS+=(--index-url "${HERMES_PIP_INDEX}")
    # ⚠ 构建机 python3 可能没有 pip 模块（WSL Debian 实测就没有）→ 先 ensurepip。
    if ! "${STAMP_PY}" -m pip --version > /dev/null 2>&1; then
        echo "[build]   python3 缺 pip，ensurepip 补装…"
        "${STAMP_PY}" -m ensurepip --upgrade >> /dev/null 2>&1             || { echo "✗ python3 无 pip 且 ensurepip 失败"; exit 1; }
    fi
    "${STAMP_PY}" -m pip "${PIP_ARGS[@]}" 2>&1 | tail -20         || { echo "✗ wheelhouse 下载失败（上方为 pip 输出）"; exit 1; }
    echo "[build]   wheelhouse ✓ ($(ls "${RT}/wheelhouse" | wc -l) 个, $(du -sh "${RT}/wheelhouse" | cut -f1))"
fi

# ── 4. 前端预构建（web_dist）────────────────────────────────
# 实测踩到的坑：
#  a) 依赖必须 `npm ci --ignore-scripts`：某些包的 postinstall（如
#     unicode-animations）会联网下载资源而**挂死**（CPU 0s、十几分钟不动）——
#     上游 package.json 自己也把它禁了（allowScripts: {unicode-animations: false}）。
#  b) 上游 `_build_web_ui` 会先做 **TypeScript 全量类型检查**（tsc solution
#     builder，进程内跑、不起子进程），大型 React 项目上极慢（实测十几分钟）；
#     而类型检查**只做校验、不产出文件**，对 web_dist 无影响。故这里直接用
#     等价构建（跳过 typecheck，只跑 vite），实测 10 秒出产物。
#     HERMES_WEB_TYPECHECK=1 可改回上游的完整构建（含类型检查）。
if [ "${SKIP_WEB}" = "1" ] && [ -f "${SRC}/hermes_cli/web_dist/index.html" ]; then
    echo "[build] --skip-web：复用已有 web_dist"
    cp -r "${SRC}/hermes_cli/web_dist" "${RT}/web_dist"
else
    need node; need npm
    # 国内可设 HERMES_NPM_REGISTRY 走镜像加速（如 https://registry.npmmirror.com）
    NPM_REG=()
    [ -n "${HERMES_NPM_REGISTRY:-}" ] && NPM_REG=(--registry "${HERMES_NPM_REGISTRY}")
    echo "[build] 装前端依赖（npm ci --ignore-scripts，避开会挂死的 postinstall）"
    ( cd "${SRC}" && npm ci --no-audit --no-fund --ignore-scripts "${NPM_REG[@]}" ) \
      || { echo "  npm ci 失败，回退 npm install"; \
           ( cd "${SRC}" && npm install --no-audit --no-fund --ignore-scripts "${NPM_REG[@]}" ); }

    if [ "${HERMES_WEB_TYPECHECK:-0}" = "1" ]; then
        echo "[build] 前端构建（上游完整入口，含 TypeScript 类型检查，较慢）"
        ( cd "${SRC}" && "${STAMP_PY}" -c "
from pathlib import Path
from hermes_cli.main_web_build import _build_web_ui
import sys
sys.exit(0 if _build_web_ui(Path('${SRC}') / 'web', fatal=True) else 1)
" ) || { echo "✗ 前端构建失败"; exit 1; }
    else
        echo "[build] 前端构建（跳过 typecheck，仅 vite 打包）"
        # 复用上游 frontend-common/freshness 辅助，保证产物布局与上游一致
        cp "${HERE}/web-build.mjs" "${SRC}/.hermes-web-build.mjs"
        ( cd "${SRC}" && node .hermes-web-build.mjs ) \
            || { echo "✗ 前端构建失败"; exit 1; }
        rm -f "${SRC}/.hermes-web-build.mjs"
    fi
    [ -f "${SRC}/hermes_cli/web_dist/index.html" ] \
        || { echo "✗ 前端构建未产出 hermes_cli/web_dist/index.html"; exit 1; }
    cp -r "${SRC}/hermes_cli/web_dist" "${RT}/web_dist"
fi
[ -f "${RT}/web_dist/index.html" ] || { echo "✗ 缺 web_dist/index.html"; exit 1; }

# 端口直连（http://NAS:9119）需要：产物里的 /app/hermes/assets/… 能落到真实文件。
# 前端按 base=/app/hermes/ 构建，而 dashboard 只挂 /assets；经飞牛网关时代理会剥前缀，
# 直连时不会 → 命中 SPA 兜底路由、以 text/html 返回 → module 脚本被 MIME 拒绝 → 白屏
# （2026-11-02 实机报告）。给前缀建一个指向自身的软链即可。
# ⚠ 打包与运行期都要有：cmd/main 启动时补一次（幂等）。
mkdir -p "${RT}/web_dist/app"
ln -sfn .. "${RT}/web_dist/app/hermes"
echo "[build] web_dist ✓ ($(du -sh "${RT}/web_dist" | cut -f1))，已建 /app/hermes 前缀别名"

# 把前端构建脚本随包分发 —— 在线更新重建 web_dist 时需要它注入 /app/hermes 前缀，
# 否则会走上游 npm run build（不带 base）→ 前缀丢失 → 白屏。
cp "${HERE}/web-build.mjs" "${RT}/web-build.mjs"

# ── 5. 桌面入口 + 网关代理（ui 必须在 app/ 内）───────────────
mkdir -p "${APP_DIR}/ui/images"
cp "${PKG_DIR}/ui/config" "${APP_DIR}/ui/config"
cp "${PKG_DIR}/ui-images/icon_64.png"  "${APP_DIR}/ui/images/icon_64.png"
cp "${PKG_DIR}/ui-images/icon_256.png" "${APP_DIR}/ui/images/icon_256.png"
# 统一网关适配层（替代官方 Go wrapper）
cp "${HERE}/gateway-proxy.py" "${APP_DIR}/gateway-proxy.py"
# .env 读写助手（cmd/main 与 cmd/*_callback 共用，保证与 python-dotenv 逐字节一致）
cp "${HERE}/envfile.sh" "${APP_DIR}/envfile.sh"
# 运行期安装脚本（uv → 源码 → PM 建 venv 装依赖）
mkdir -p "${APP_DIR}/scripts"
cp "${HERE}/install-runtime.sh" "${APP_DIR}/scripts/install-runtime.sh"
chmod 755 "${APP_DIR}/scripts/install-runtime.sh"
# 注：不再提供 bin/hermes-update。源码在数据目录且带 .git，
# 直接用上游 `hermes update`（CLI 入口在 bin/hermes）。

# hermes CLI：usr-local-linker 会把 app/bin/hermes 链接进 PATH，
# 于是 SSH 里可直接 `hermes doctor` / `hermes setup` / `hermes model` …
# 不加它，doctor 输出里的所有「run 'hermes …'」建议都不可执行（command not found）。
# 环境变量与 cmd/main 组装的 dashboard/gateway 启动环境保持一致（同一套 HERMES_*）。
# ⚠ 路径/解释器/node/工作区 的解析必须逐条对齐 cmd/main（不能硬编码）：
#   裸 SSH 会话里没有 fnOS 注入的 TRIM_* 变量 —— 尤其工作区，若不单独探
#   /vol*/@appshare/hermes/workspace，HERMES_WRITE_SAFE_ROOT 会错算成
#   ${DATA}/workspace，让 CLI 的写安全边界指到错误目录（真机实测发现）。
mkdir -p "${APP_DIR}/bin"
cat > "${APP_DIR}/bin/hermes" <<'WRAP'
#!/bin/bash
# Hermes CLI —— fnOS 打包版。
# 目的：让 `hermes <子命令>`（doctor/setup/skills/status/cron/tools/auth/mcp…）可用。
# 上游 install.sh 靠 venv console script 生成该入口；本包是「自带 CPython +
# python -m hermes_cli.main」。机制同 usr-local-linker 的其它入口
# （fnOS 把 fpk 的 bin/ 里每个文件软链到 /usr/local/bin）。
# 路径/解释器/node/工作区解析逐条对齐 cmd/main → 跨卷、跨 node 版本、
# 跨「系统 Python ↔ 自带 CPython」模式切换都成立。
set -u
APP="hermes"

# 应用目录：TRIM_APPDEST → /var/apps 统一视图 → 脚本自身位置
if [ -n "${TRIM_APPDEST:-}" ] && [ -d "${TRIM_APPDEST}" ]; then
    APP_DIR="$(readlink -f "${TRIM_APPDEST}")"
elif [ -d "/var/apps/${APP}/target" ]; then
    APP_DIR="$(readlink -f "/var/apps/${APP}/target")"
else
    APP_DIR="$(readlink -f "$(dirname "$(readlink -f "$0")")/..")"
fi

# 数据目录（跨重装持久）
if [ -n "${TRIM_PKGVAR:-}" ]; then
    DATA_DIR="${TRIM_PKGVAR}"
elif [ -d "/var/apps/${APP}/var" ]; then
    DATA_DIR="$(readlink -f "/var/apps/${APP}/var")"
else
    DATA_DIR="${APP_DIR}/../var"
fi

# 新布局：源码在数据目录（git clone 自带 .git，支持 hermes update）
SRC_DIR="${DATA_DIR}/src"
WEB_DIST="${APP_DIR}/runtime/web_dist"

# 工作区：与 cmd/main 的 resolve_workspace() 同逻辑
WS=""
if [ -n "${TRIM_DATA_SHARE_PATHS:-}" ]; then
    _ifs_save="${IFS}"; IFS=':'
    for p in ${TRIM_DATA_SHARE_PATHS}; do
        case "${p}" in */hermes/workspace) WS="${p}"; break ;; esac
    done
    if [ -z "${WS}" ]; then
        for p in ${TRIM_DATA_SHARE_PATHS}; do
            [ -n "${p}" ] && { WS="${p}"; break; }
        done
    fi
    IFS="${_ifs_save}"
fi
if [ -z "${WS}" ]; then
    # 裸 SSH 会话没有 TRIM_DATA_SHARE_PATHS，直接探 share 路径
    for d in /vol*/@appshare/${APP}/workspace; do
        [ -d "${d}" ] && { WS="${d}"; break; }
    done
fi
[ -n "${WS}" ] || WS="${DATA_DIR}/workspace"

_py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
# 解释器：PM 管理的 venv（从 facts.json 读当前 generation）→ PATH 兜底
PY=""
if [ -d "${DATA_DIR}/installs" ]; then
    _facts="$(find "${DATA_DIR}/installs" -maxdepth 2 -name facts.json -type f -not -path '*.disabled-*' 2>/dev/null | head -n 1)"
    if [ -n "${_facts}" ] && [ -n "${_py}" ]; then
        _venv="$("${_py}" -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8-sig'));print(((d.get('packages') or {}).get('venv') or {}).get('environment') or '')" "${_facts}" 2>/dev/null)"
        [ -n "${_venv}" ] && [ -x "${_venv}/bin/python3" ] && PY="${_venv}/bin/python3"
    fi
fi
[ -n "${PY}" ] || PY="$(command -v python3)"

# node：与 cmd/main 的 find_node_bin() 同逻辑（TUI 终端要用）。
# ⚠ 按【版本】分层（v24 → v22），每档覆盖 /var/apps 与跨卷 @appcenter 两种形态；
#   v22 档校验 engines 下限（^22.22.0，应用中心的 22.18.0 会被跳过）。
#   <data>/node 是 Hermes 按需下载的托管 node（通常过时），只作兜底。
NODE=""
for _mj in 26 24 22; do
    [ -n "${NODE}" ] && break
    for d in /var/apps/nodejs_v${_mj}/target/bin/node \
             /var/apps/nodejs_v${_mj}/bin/node \
             /vol*/@appcenter/nodejs_v${_mj}/bin/node; do
        [ -x "${d}" ] || continue
        if [ "${_mj}" = "22" ]; then
            _ver="$("${d}" -v 2>/dev/null)"
            [ "$(printf '%s\nv22.22.0\n' "${_ver}" | sort -V | tail -n 1)" = "${_ver}" ] || continue
        fi
        NODE="${d}"; break
    done
done
if [ -z "${NODE}" ] && [ -x "${DATA_DIR}/node/bin/node" ]; then NODE="${DATA_DIR}/node/bin/node"; fi
if [ -z "${NODE}" ]; then
    d="$(command -v node 2>/dev/null || true)"
    [ -n "${d}" ] && [ -x "${d}" ] && NODE="${d}"
fi
if [ -z "${NODE}" ]; then
    for d in /vol*/@appcenter/nodejs_v25/bin/node /vol*/@appcenter/nodejs_v26/bin/node; do
        [ -x "${d}" ] && { NODE="${d}"; break; }
    done
fi
# ⚠ 必须把 node 的目录加进 PATH，不能只设 HERMES_NODE：
#   HERMES_NODE 只告诉 Hermes「node 在哪」，而那些 npm/npx shim 的首行是
#   `#!/usr/bin/env node` —— env 走的是 PATH，跟 HERMES_NODE 无关。npx 驱动的
#   流程（装浏览器 / 装 MCP 依赖）否则会 `env: 'node': No such file or directory`
#   （真机实测，且上游会假报成功）。
if [ -n "${NODE}" ]; then
    NODE_DIR="$(dirname "${NODE}")"
    case ":${PATH}:" in
        *":${NODE_DIR}:"*) : ;;
        *) export PATH="${NODE_DIR}:${PATH}" ;;
    esac
    export HERMES_NODE="${NODE}"
fi

# 浏览器（Chromium）路径：与 cmd/main 的 browser_env() 同逻辑（策略一致）。
# agent-browser 装到 <data>/.agent-browser/browsers/chrome-*/chrome，而 Hermes 的
# 就绪检测默认只扫 Playwright 的 <home>/.cache/ms-playwright → 装成功仍报「缺失」。
# 本变量是该检测的第一顺位。⚠ 用 sort -V 按版本号取最新（裸 glob 是字典序，
# chrome-99.x 会盖过 chrome-155.x）；版本目录优先，chrome-current 软链兜底。
BROWSER_BASE="${DATA_DIR}/.agent-browser"
CHROME_BIN=""
# while read + 进程替换（保空格；`for in $(ls …)` 会按空白分词拆碎含空格路径）。
# glob 不匹配时列出字面量，由 [ -x ] 过滤。
while IFS= read -r _c; do
    [ -x "${_c}" ] && { CHROME_BIN="${_c}"; break; }
done < <(printf '%s\n' "${BROWSER_BASE}/browsers/"*/chrome | sort -Vr)
[ -n "${CHROME_BIN}" ] || { [ -x "${BROWSER_BASE}/chrome-current" ] && CHROME_BIN="${BROWSER_BASE}/chrome-current"; }
[ -n "${CHROME_BIN}" ] && export AGENT_BROWSER_EXECUTABLE_PATH="${CHROME_BIN}"

# TMPDIR 指向 ${WS}/tmp（工作区内）—— 自动 TTS 等把产物写进 tempdir 的流程，
# 其路径必须落在 HERMES_WRITE_SAFE_ROOT 内，否则被写安全闸门拒绝（真机报告：
# 自动语音回复永久失效，且失败被静默吞掉）。upstream 的 apply_scratch_tmp_env
# 只在 TMPDIR "未设置" 时才覆盖 —— 这里显式设好即可，且它认得这是外部设置。
mkdir -p "${WS}/tmp" 2>/dev/null || true
export TMPDIR="${WS}/tmp" TMP="${WS}/tmp" TEMP="${WS}/tmp"

# 转交 CLI。环境与 cmd/main 启动应用时保持同一套 HERMES_*
# stderr 过滤：上游 v0.22 的 check_runtime() 拿 pm store 的 21 个产品做漂移比对，
# 而本包工具由应用中心/系统提供（rg 在 /usr/local/bin、node 在 nodejs_v24、
# ffmpeg 在 /usr/bin），store 里只登记 python/uv → 每条命令都打一行
# "install out of sync (ffmpeg/node/npm/ripgrep …)"。工具实际都在，纯噪声。
# 这里只滤掉这一行，其余输出（含真实错误）原样透传。
_err="$(mktemp 2>/dev/null || echo "${DATA_DIR}/.hermes-shim-err.$$")"
trap 'rm -f "${_err}"' EXIT
env \
    HOME="${DATA_DIR}" \
    PYTHONPATH="${SRC_DIR}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HERMES_HOME="${DATA_DIR}" \
    HERMES_BUNDLED_SKILLS="${SRC_DIR}/skills" \
    HERMES_OPTIONAL_SKILLS="${SRC_DIR}/optional-skills" \
    HERMES_BUNDLED_PLUGINS="${SRC_DIR}/plugins" \
    HERMES_BUNDLED_LOCALES="${SRC_DIR}/locales" \
    HERMES_OPTIONAL_MCPS="${SRC_DIR}/optional-mcps" \
    HERMES_WEB_DIST="${WEB_DIST}" \
    HERMES_WRITE_SAFE_ROOT="${WS}" \
    HERMES_MANAGED_BY="trim-hermes-fnos" \
    HERMES_TUI_WS_ORPHAN_REAP_GRACE_S="300" \
    "${PY}" -m hermes_cli.main "$@" 2>"${_err}"
_rc=$?
grep -v '^⚠ install out of sync' "${_err}" >&2 || true
exit "${_rc}"
WRAP
chmod 755 "${APP_DIR}/bin/hermes"

# ripgrep：Hermes 的 search_files 工具靠 PATH 上的 `rg`（shutil.which("rg")），
# 缺它退化成 grep、大仓库搜索变慢。上游 install.sh 默认会装；本包打进 bin/，
# 经 usr-local-linker 落到 /usr/local/bin。静态 musl 版，无 glibc 依赖。
# 失败不阻断构建（rg 是可选加速项）—— 见下方按需从 resource 里摘掉 bin/rg。
if [ "${HERMES_SKIP_RIPGREP:-0}" != "1" ]; then
    case "${PBS_TRIPLE}" in
        x86_64-unknown-linux-gnu)  RG_TRIPLE="x86_64-unknown-linux-musl" ;;
        aarch64-unknown-linux-gnu) RG_TRIPLE="aarch64-unknown-linux-musl" ;;
        *)                         RG_TRIPLE="" ;;
    esac
    RG_TGZ="${PBS_CACHE}/ripgrep-${RG_TRIPLE}.tar.gz"
    if [ -n "${RG_TRIPLE}" ] && [ ! -f "${RG_TGZ}" ]; then
        RG_URL="https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-${RG_TRIPLE}.tar.gz"
        # 国内可设 HERMES_GH_MIRROR 走加速（与 PBS 下载同一开关）
        RG_URL="${HERMES_GH_MIRROR:+${HERMES_GH_MIRROR}/}${RG_URL}"
        echo "[build] 下载 ripgrep（可选）→ ${RG_URL}"
        curl -fL --retry 3 -o "${RG_TGZ}.part" "${RG_URL}" 2>/dev/null \
            && mv "${RG_TGZ}.part" "${RG_TGZ}" \
            || { rm -f "${RG_TGZ}.part"; echo "[build] ⚠ ripgrep 下载失败（跳过）"; }
    fi
    if [ -f "${RG_TGZ}" ]; then
        RG_TMP="$(mktemp -d)"
        tar -xzf "${RG_TGZ}" -C "${RG_TMP}" 2>/dev/null || true
        RG_BIN="$(find "${RG_TMP}" -type f -name rg 2>/dev/null | head -n 1)"
        if [ -n "${RG_BIN}" ]; then
            cp "${RG_BIN}" "${APP_DIR}/bin/rg"
            chmod 755 "${APP_DIR}/bin/rg"
            echo "[build] ✓ 打包 ripgrep → bin/rg ($("${APP_DIR}/bin/rg" --version 2>/dev/null | head -1 || echo '?'))"
        else
            echo "[build] ⚠ ripgrep 解包异常（跳过）"
        fi
        rm -rf "${RG_TMP}"
    fi
fi
# 包根图标（fnOS 规范）
cp "${PKG_DIR}/ui-images/icon_64.png"  "${STAGE}/ICON.PNG"
cp "${PKG_DIR}/ui-images/icon_256.png" "${STAGE}/ICON_256.PNG"

# ── 6. 自检 ──────────────────────────────────────────────────
if grep -rn -e '{port}' -e '{display_name}' "${APP_DIR}/ui" > /dev/null 2>&1; then
    echo "✗ ui/ 里仍有 {port} / {display_name} 占位符 → 桌面图标会点了没反应"
    exit 1
fi
# 运行期不再预置：不应出现 python/ 或源码树
[ -d "${RT}/python" ] && { echo "✗ 仍打包了 runtime/python（本版应在安装期获取）"; exit 1; }
[ -d "${RT}/hermes" ] && { echo "✗ 仍打包了源码树（本版应在安装期 clone）"; exit 1; }
[ -f "${RT}/deps.txt" ] && { echo "✗ 仍打包了 deps.txt（本版应在安装期由 PM 解析）"; exit 1; }
# 必须有的安装期组件
[ -f "${APP_DIR}/scripts/install-runtime.sh" ] || { echo "✗ 缺 scripts/install-runtime.sh"; exit 1; }
[ -f "${APP_DIR}/upstream-ref" ] || { echo "✗ 缺 upstream-ref"; exit 1; }
[ -f "${RT}/install-stamp.json" ] || { echo "✗ 缺 install-stamp.json"; exit 1; }
[ -f "${RT}/web_dist/index.html" ] || { echo "✗ 缺预构建前端 web_dist/index.html"; exit 1; }

# ── 7. manifest / cmd / config / wizard ─────────────────────
echo "[build] 写 manifest"
sed -e "s/^version  *=.*/version               = ${VERSION}/" \
    -e "s/^platform  *=.*/platform              = ${MANIFEST_PLATFORM}/" \
    "${PKG_DIR}/manifest" > "${STAGE}/manifest"

cp -r "${PKG_DIR}/cmd"    "${STAGE}/cmd"
cp -r "${PKG_DIR}/config" "${STAGE}/config"
cp -r "${PKG_DIR}/wizard" "${STAGE}/wizard"
chmod 755 "${STAGE}/cmd/"*

### 目录权限统一为 755（常规做法，非升级问题修复）。
### 注：2026-10-24 曾怀疑「平台复制到临时目录时把目录降为 644 导致解包失败」，
### 但后续实测推翻了该假设（/vol1 带 trimacl，644 不阻断；平台解包进程是 root）。
### 真正的升级失败根因是 uninstall_callback 的自我误杀（见该文件注释）。
### 这里保留 755 设置本身（显式权限无害），但不要用它解释升级问题。
find "${STAGE}" -type d -exec chmod 755 {} \; 2>/dev/null || true


# config/resource 里 usr-local-linker 列了 bin/hermes 与 bin/rg。
# rg 是可选下载（见步骤 5），失败时它不在 app 里 —— 此时把 "bin/rg" 从 resource
# 摘掉，避免 linker 指向不存在的文件。bin/hermes 恒存在，不动。
# python3 在构建机必然可用（build.sh 前置就用它抽 deps.txt/写 stamp）。
if [ ! -f "${APP_DIR}/bin/rg" ] && grep -q '"bin/rg"' "${STAGE}/config/resource"; then
    "${STAMP_PY}" - "${STAGE}/config/resource" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
bins = (d.get("usr-local-linker") or {}).get("bin") or []
if "bin/rg" in bins:
    bins.remove("bin/rg")
    d["usr-local-linker"]["bin"] = bins
open(p, "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PY
    echo "[build] ⚠ 未打包 ripgrep → 已从 config/resource 移除 bin/rg"
fi

# ── 8. 打包 ──────────────────────────────────────────────────
FINAL="${DIST}/hermes-${VERSION}.fpk"
rm -f "${FINAL}"

if [ -n "${FNPACK}" ]; then
    echo "[build] fnpack build → ${FINAL}"
    ( cd "${DIST}" && "${FNPACK}" build -d "$(winpath "${STAGE}")" )
    if [ ! -f "${FINAL}" ] && [ -f "${DIST}/hermes.fpk" ]; then
        mv "${DIST}/hermes.fpk" "${FINAL}"
    fi
else
    # CI 等价打包：fpk = tar.gz，内部 app.tgz（app/ 目录）+ 包根其余文件。
    echo "[build] fnpack 不可用，手动打包 → ${FINAL}"
    APP_TGZ="${DIST}/.app.tgz"
    ( cd "${APP_DIR}" && tar -czf "${APP_TGZ}" . )
    cp "${APP_TGZ}" "${STAGE}/app.tgz"
    rm -f "${APP_TGZ}"
    ( cd "${STAGE}" && tar -czf "${FINAL}" manifest ICON.PNG ICON_256.PNG \
        app.tgz cmd config wizard )
    rm -f "${STAGE}/app.tgz"
fi
[ -f "${FINAL}" ] || { echo "✗ 没有产出 ${FINAL}"; ls -la "${DIST}"; exit 1; }

echo "[build] ✓ ${FINAL} ($(du -h "${FINAL}" | cut -f1))"

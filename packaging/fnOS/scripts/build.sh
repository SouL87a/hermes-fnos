#!/usr/bin/env bash
#
# 构建飞牛 fnOS 原生应用包（.fpk）—— Hermes Agent
# ===============================================
# 产物：packaging/fnOS/dist/hermes-<version>.fpk
#
# payload 不是上游的现成 runtime（上游只给安装脚本，靠 uv 现拉），而是本地装配：
#   1. python-build-standalone 的 CPython 3.14（可重定位，随包分发）
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
while [ $# -gt 0 ]; do
    case "$1" in
        --src)      SRC_DIR_ARG="${2:-}"; shift 2 ;;
        --skip-web) SKIP_WEB=1; shift ;;
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

# ── 版本号：跟随上游 ─────────────────────────────────────────
# fpk 版本 = 上游 ref 的版本（与 dashboard 左下角、install-stamp 一致），
# 这样应用中心显示的版本能直接反映"当前是哪个 Hermes"。
#   v0.21.4+canary.20261001T070239Z → 0.21.4
#   v2026.9.24                     → 2026.9.24
# 覆盖顺序：HERMES_VERSION 环境变量 > 上游 ref 推导 > fnos.version 兜底。
UPSTREAM_REF_V="$(grep -vE '^\s*#|^\s*$' "${REPO}/upstream.version" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
VERSION="${HERMES_VERSION:-}"
if [ -z "${VERSION}" ] && [ -n "${UPSTREAM_REF_V}" ]; then
    VERSION="$(printf '%s' "${UPSTREAM_REF_V}" | sed -E 's/^v//; s/[+-].*$//')"
fi
if [ -z "${VERSION}" ] && [ -f "${REPO}/fnos.version" ]; then
    VERSION="$(grep -vE '^\s*#|^\s*$' "${REPO}/fnos.version" | head -n 1 | tr -d '[:space:]')"
fi
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

# ── 1. CPython 运行时（python-build-standalone）──────────────
# 用 3.14：上游 main/canary 已迁 3.14（requires-python >=3.11,<3.15）。默认自带
# CPython，运行期零联网。3.14 较新，个别原生轮子可能暂无 cp314 wheel（构建时
# 会退化成源码编译）——盯构建日志里 `Building wheel for ...` 的行。
# 若改回复用系统 Python，设 HERMES_USE_SYSTEM_PYTHON=1（见下方分支）。
PY_VERSION="${HERMES_PY_VERSION:-3.14.7}"
PBS_TAG="${HERMES_PBS_TAG:-20260929}"     # 可覆盖；脚本会从 release 资产里挑匹配项
PBS_CACHE="${PKG_DIR}/.cache"
mkdir -p "${PBS_CACHE}"

pbs_url() {
    # 资产名形如：cpython-<ver>+<tag>-<triple>-install_only.tar.gz
    local base="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}"
    local asset="cpython-${PY_VERSION}+${PBS_TAG}-${PBS_TRIPLE}-install_only.tar.gz"
    # 国内可设 HERMES_GH_MIRROR 走加速（如 https://ghfast.top），显著提速
    echo "${HERMES_GH_MIRROR:+${HERMES_GH_MIRROR}/}${base}/${asset}"
}

PBS_TGZ="${PBS_CACHE}/cpython-${PY_VERSION}-${PBS_TRIPLE}.tar.gz"
if [ "${HERMES_USE_SYSTEM_PYTHON:-0}" = "1" ]; then
    # 复用系统 Python（你在飞牛已装的 3.12）：不打包 CPython，运行期直接用
    # 系统 python3。代价：依赖要在安装时联网装（构建期无法预装到系统解释器）。
    echo "[build] HERMES_USE_SYSTEM_PYTHON=1：跳过打包 CPython，运行期用系统 python3"
    PYBIN="$(command -v python3 || command -v python)"
    [ -n "${PYBIN}" ] || { echo "✗ 本机找不到 python3（系统 Python 模式下构建机也需要它来预装/校验）"; exit 1; }
    "${PYBIN}" --version
    # 标记：cmd/main 见到此文件即改用系统 python3
    : > "${RT}/.use-system-python"
else
    if [ ! -f "${PBS_TGZ}" ]; then
        URL="$(pbs_url)"
        echo "[build] 下载 CPython ${PY_VERSION} → ${URL}"
        if ! curl -fL --retry 3 -o "${PBS_TGZ}.part" "${URL}"; then
            rm -f "${PBS_TGZ}.part"
            echo "✗ 下载 CPython 失败。请确认 PBS_TAG/PY_VERSION 组合存在："
            echo "  https://github.com/astral-sh/python-build-standalone/releases"
            echo "  可用 HERMES_PBS_TAG=YYYYMMDD HERMES_PY_VERSION=3.12.x 覆盖。"
            exit 1
        fi
        mv "${PBS_TGZ}.part" "${PBS_TGZ}"
    fi
    echo "[build] 解包 CPython → runtime/python"
    mkdir -p "${RT}/python"
    tar -xzf "${PBS_TGZ}" -C "${RT}/python" --strip-components=1
    PYBIN="${RT}/python/bin/python3"
    [ -x "${PYBIN}" ] || { echo "✗ CPython 解包异常，缺 ${PYBIN}"; exit 1; }
    "${PYBIN}" --version
fi

# ── 2. 依赖 ──────────────────────────────────────────────────
# 打包模式：装进包内 CPython 的 site-packages，运行期零联网。
# 系统 Python 模式：构建期无法往 NAS 的系统解释器里装，改为安装时（install_callback）
#   用 uv 在 NAS 上建 venv 并装依赖 —— 见 cmd/install_callback。
### 无论哪种模式，都先从源码树抽依赖清单（系统 Python 模式随包分发，安装时用）。
DEPS_TXT="${RT}/deps.txt"
"${PYBIN}" - "${SRC}/pyproject.toml" > "${DEPS_TXT}" <<'PY'
import sys, tomllib, pathlib
p = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
proj = p["project"]
deps = list(proj.get("dependencies", []))
extras = proj.get("optional-dependencies", {})
# 装哪些 extra：
#   web       —— dashboard 服务端（fastapi/uvicorn）
#   messaging —— 消息平台适配器（aiohttp 等）。缺它则 QQ/Telegram 等
#                适配器建不出来，gateway 日志报 "No adapter available"
#                （用户实测报告 qqbot-channel-status-report.md）。
for name in ("web", "messaging"):
    deps += list(extras.get(name, []))
# 过滤自引用（形如 hermes-agent[xxx]），避免把项目本身拉进来
out = [d for d in deps if not d.strip().lower().startswith("hermes-agent")]
print("\n".join(out))
PY
[ -s "${DEPS_TXT}" ] || { echo "✗ 依赖清单抽取失败（${DEPS_TXT}）"; exit 1; }
echo "[build] 依赖条数：$(grep -c . "${DEPS_TXT}")"

if [ "${HERMES_USE_SYSTEM_PYTHON:-0}" = "1" ]; then
    echo "[build] 系统 Python 模式：跳过构建期依赖安装（依赖清单已随包，安装时 uv 装）"
else
echo "[build] 安装 Python 依赖（core + [web]）→ site-packages"

### 只装依赖，不装项目本身。
### 为什么：`pip install -e <源码树>` 会把**构建机绝对路径**写进 .pth，装到 NAS 后
### 该路径不存在 → import hermes_cli 直接失败。而普通（非 editable）安装会把项目
### 拷进 site-packages，导致 PROJECT_ROOT 指向 site-packages，随包的 skills/ 等
### 顶层数据目录丢失。正解：依赖进 site-packages，代码从随包的源码树跑
### （cmd/main 里 PYTHONPATH=runtime/hermes，PROJECT_ROOT 因此指向源码树）。
### 依赖清单已在上方抽好（${DEPS_TXT}）。
if command -v uv > /dev/null 2>&1; then
    UV="uv"
elif [ -x "${HOME}/.local/bin/uv" ]; then
    UV="${HOME}/.local/bin/uv"
elif [ -x "${HOME}/.cargo/bin/uv" ]; then
    UV="${HOME}/.cargo/bin/uv"
else
    UV=""
fi

### ⚠ 交叉构建的可移植性：只取预编译 wheel，禁止本地源码编译。
### 原因：构建机 glibc 可能比目标（fnOS = Debian 12 / glibc 2.36）新，
### 本地编译出的 .so 会链接到更新的 glibc 符号版本，装到 NAS 上直接报
### "GLIBC_2.3x not found"。manylinux wheel 是针对老 glibc 构建的，安全。
### 代价：若某依赖无 cp314 wheel，构建会**明确失败**而非悄悄产出不可移植的包
### —— 这正是我们要的（宁可失败也不要装上去才崩）。
### 逃生阀：HERMES_ALLOW_SOURCE_BUILD=1 可放开（自担风险，需目标机有工具链）。
BINARY_FLAGS=()
if [ "${HERMES_ALLOW_SOURCE_BUILD:-0}" != "1" ]; then
    BINARY_FLAGS=(--only-binary=:all:)
    echo "[build] 强制仅用预编译 wheel（保证 glibc 可移植性）"
else
    echo "[build] ⚠ HERMES_ALLOW_SOURCE_BUILD=1：允许本地源码编译（可能不可移植）"
fi

### 国内可设 HERMES_PIP_INDEX 走镜像加速（如 https://pypi.tuna.tsinghua.edu.cn/simple）
INDEX_FLAGS=()
if [ -n "${HERMES_PIP_INDEX:-}" ]; then
    INDEX_FLAGS=(-i "${HERMES_PIP_INDEX}")
    echo "[build] 使用 PyPI 镜像：${HERMES_PIP_INDEX}"
fi

if [ -n "${UV}" ]; then
    echo "[build] 使用 uv：${UV}"
    "${UV}" pip install --python "$(winpath "${PYBIN}")" --no-config \
        "${BINARY_FLAGS[@]}" "${INDEX_FLAGS[@]}" -r "$(winpath "${DEPS_TXT}")"
else
    echo "[build] uv 不可用，回退 pip（较慢）"
    "${PYBIN}" -m pip install --upgrade pip > /dev/null
    "${PYBIN}" -m pip install "${BINARY_FLAGS[@]}" "${INDEX_FLAGS[@]}" -r "$(winpath "${DEPS_TXT}")"
fi
# 注意：不删 deps.txt —— 它是包内产物（runtime/deps.txt），
# 系统 Python 模式安装时要用它装依赖，最终自检也要它。

# 校验关键依赖已就位（此时源码树还没拷进包，只验第三方依赖）
"${PYBIN}" - <<'PY' || { echo "✗ 依赖校验失败"; exit 1; }
import importlib
for m in ("fastapi", "uvicorn", "starlette", "pydantic", "cryptography", "PIL", "psutil"):
    importlib.import_module(m)
print("deps ok: fastapi, uvicorn, starlette, pydantic, cryptography, PIL, psutil")
PY
fi  # 结束「打包模式」分支

# ── 3. 源码树拷进包 ──────────────────────────────────────────
echo "[build] 拷贝源码树 → runtime/hermes"
mkdir -p "${RT}/hermes"
# 关键：**保留 .git** —— 在线更新靠 git fetch/reset（用户选定「真·git 检出」）。
# 但不要完整历史：构建源是浅克隆（--depth 1），.git 本就很小；再压掉多余引用。
( cd "${SRC}" && tar -cf - \
    --exclude='node_modules' \
    --exclude='web/node_modules' \
    --exclude='ui-tui/node_modules' \
    --exclude='apps/*/node_modules' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.venv' \
    --exclude='tests' \
    --exclude='tests-js' \
    --exclude='evals' \
    --exclude='website' \
    . ) | ( cd "${RT}/hermes" && tar -xf - )

# 记录来源仓库，供 hermes-update.py 用（.git 的 origin 可能因浅克隆/打包丢失）
if [ -d "${SRC}/.git" ]; then
    git -C "${SRC}" remote get-url origin > "${RT}/.origin-url" 2>/dev/null || true
    ( cd "${RT}/hermes" && git rev-parse HEAD > "${RT}/.git-head" 2>/dev/null || true )
    # 补上 origin（打包过程可能剥离了 remote 配置）
    if [ -f "${RT}/.origin-url" ] && [ -d "${RT}/hermes/.git" ]; then
        ORIGIN_URL="$(cat "${RT}/.origin-url")"
        git -C "${RT}/hermes" remote remove origin 2>/dev/null || true
        git -C "${RT}/hermes" remote add origin "${ORIGIN_URL}" 2>/dev/null || true
    fi
fi

# ── 3b. install-stamp.json（Hermes 版本的权威来源）───────────
# Hermes 的版本解析顺序：install-stamp.json → 活的 .git → unknown。
# 不写这个戳，dashboard 左下角会显示 "vunknown"。
#
# updateMechanism 取值决定更新归属：
#   self     → 上游 `hermes update` 放行（但它要求 venv/PM 布局，与自带 CPython 冲突）
#   external → 上游明确拒绝并提示"由安装方式管理"，更新走我们自己的
#              hermes-update.py（dashboard 的 /__hermes/update/ui 或 SSH 命令）
# 本项目用 external（更新链路自管，见 README）。
echo "[build] 生成 install-stamp.json"
STAMP="${RT}/hermes/install-stamp.json"
STAMP_COMMIT="$(git -C "${SRC}" rev-parse HEAD 2>/dev/null || echo '')"
STAMP_BRANCH="$(git -C "${SRC}" branch --show-current 2>/dev/null || echo '')"
STAMP_DATE="$(git -C "${SRC}" log -1 --format=%ct 2>/dev/null || echo '')"
# 从上游 ref 推导基础版本：v0.21.4+canary.xxx → 0.21.4；v2026.9.24 → 2026.9.24
# 与 fpk 版本统一（同一份推导，避免两处漂移）
STAMP_BASE="${VERSION}"
UPSTREAM_REF="${UPSTREAM_REF_V}"
[ -n "${STAMP_COMMIT}" ] || STAMP_COMMIT="$(printf '0%.0s' $(seq 1 40))"

# 用构建机上任意可用的 python 写 stamp（不需要包内运行时）
STAMP_PY=""
for cand in "${PYBIN}" python3 python; do
    if command -v "${cand}" > /dev/null 2>&1; then STAMP_PY="${cand}"; break; fi
done
[ -n "${STAMP_PY}" ] || { echo "✗ 找不到 python 用于生成 install-stamp.json"; exit 1; }

"${STAMP_PY}" - "$(winpath "${STAMP}")" "$STAMP_COMMIT" "$STAMP_BASE" "$STAMP_BRANCH" "$STAMP_DATE" <<'PY'
import json, sys, datetime
out, commit, base, branch, cdate = sys.argv[1:6]
stamp = {
    "schemaVersion": 2,
    "commit": commit,
    "commitDate": int(cdate) if cdate.isdigit() else None,
    "branch": branch or None,
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "dirty": False,
    "source": "local",          # 非 commit-build/docker/nix → 不触发额外拒绝
    "distribution": None,       # 不声明发行形态
    "updateMechanism": "external",  # 更新由本包的 hermes-update.py 管理
    "baseVersion": base,
    "displayVersion": base,
    "distance": 0,
}
# payload 字段刻意不写：写了 bundled/light/runtime 会被判为"不可自更新"，
# 这里要保持与 external 一致但语义清晰。
open(out, "w", encoding="utf-8").write(json.dumps(stamp, ensure_ascii=False, indent=2) + "\n")
print(f"[build]   stamp: base={base} commit={commit[:12] or '(none)'} mechanism=external")
PY
[ -f "${STAMP}" ] || { echo "✗ install-stamp.json 生成失败"; exit 1; }

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
        ( cd "${SRC}" && "${PYBIN}" -c "
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
echo "[build] web_dist ✓ ($(du -sh "${RT}/web_dist" | cut -f1))"

# 把前端构建脚本随包分发 —— 在线更新（hermes-update.py）重建 web_dist 时
# 必须用它，否则会走上游 npm run build（不带 base 注入）→ 前缀丢失 → 黑屏。
cp "${HERE}/web-build.mjs" "${RT}/web-build.mjs"

# ── 4b. TUI bundle（对话页底部终端依赖它）────────────────────
# 上游 main_tui_launch 按序查找 entry.js：
#   $HERMES_TUI_DIR/dist/entry.js → hermes_cli/tui_dist/entry.js → <repo>/ui-tui/dist/entry.js
# 缺它则对话页终端是黑框（实测报告缺陷 3）。官方 trim.hermes 自带该文件。
# 这里用上游 scripts/build/tui.mjs（esbuild）构建，产出落到 hermes_cli/tui_dist/。
if [ "${SKIP_TUI:-0}" = "1" ] && [ -f "${SRC}/hermes_cli/tui_dist/entry.js" ]; then
    echo "[build] --skip-tui：复用已有 tui_dist"
else
    if [ -f "${SRC}/scripts/build/tui.mjs" ]; then
        echo "[build] 构建 TUI bundle（上游 scripts/build/tui.mjs）"
        # --out 必须在源码树外（上游 productOutput 校验：树内路径会被当作构建输入）
        TUI_OUT="${PKG_DIR}/.cache/tui-out"
        rm -rf "${TUI_OUT}"
        ( cd "${SRC}" && node scripts/build/tui.mjs --source "${SRC}" \
            --out "${TUI_OUT}" ) \
          || { echo "✗ TUI 构建失败"; exit 1; }
        mkdir -p "${SRC}/hermes_cli/tui_dist"
        if [ -f "${TUI_OUT}/dist/entry.js" ]; then
            cp "${TUI_OUT}/dist/entry.js" "${SRC}/hermes_cli/tui_dist/entry.js"
        elif [ -f "${SRC}/ui-tui/dist/entry.js" ]; then
            cp "${SRC}/ui-tui/dist/entry.js" "${SRC}/hermes_cli/tui_dist/entry.js"
        else
            echo "✗ TUI 构建未产出 entry.js"; exit 1
        fi
    else
        echo "⚠ 上游无 scripts/build/tui.mjs，跳过 TUI 构建（对话页终端将不可用）"
    fi
fi
if [ -f "${SRC}/hermes_cli/tui_dist/entry.js" ]; then
    mkdir -p "${RT}/hermes/hermes_cli/tui_dist"
    cp "${SRC}/hermes_cli/tui_dist/entry.js" "${RT}/hermes/hermes_cli/tui_dist/entry.js"
    echo "[build] tui_dist ✓ ($(du -h "${RT}/hermes/hermes_cli/tui_dist/entry.js" | cut -f1))"
else
    echo "⚠ 未产出 tui_dist/entry.js —— 对话页终端将不可用"
fi

# ── 5. 桌面入口 + 网关代理（ui 必须在 app/ 内）───────────────
mkdir -p "${APP_DIR}/ui/images"
cp "${PKG_DIR}/ui/config" "${APP_DIR}/ui/config"
cp "${PKG_DIR}/ui-images/icon_64.png"  "${APP_DIR}/ui/images/icon_64.png"
cp "${PKG_DIR}/ui-images/icon_256.png" "${APP_DIR}/ui/images/icon_256.png"
# 统一网关适配层（替代官方 Go wrapper）
cp "${HERE}/gateway-proxy.py" "${APP_DIR}/gateway-proxy.py"
# 在线更新引擎
cp "${HERE}/hermes-update.py" "${APP_DIR}/hermes-update.py"
# CLI 包装：usr-local-linker 会把 app/bin/hermes-update 链接进 PATH，
# 于是 SSH 里可直接 `hermes-update check|apply`。
mkdir -p "${APP_DIR}/bin"
cat > "${APP_DIR}/bin/hermes-update" <<'WRAP'
#!/bin/bash
# Hermes 在线更新 CLI（fnOS）。转发到 hermes-update.py。
APP_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PY="${APP_DIR}/runtime/python/bin/python3"
[ -x "${PY}" ] || PY="$(command -v python3)"
DATA="${TRIM_PKGVAR:-/var/apps/hermes/var}"
exec env HERMES_APP_ROOT="${APP_DIR}" HERMES_DATA_ROOT="${DATA}" "${PY}" "${APP_DIR}/hermes-update.py" "$@"
WRAP
chmod 755 "${APP_DIR}/bin/hermes-update"
# 包根图标（fnOS 规范）
cp "${PKG_DIR}/ui-images/icon_64.png"  "${STAGE}/ICON.PNG"
cp "${PKG_DIR}/ui-images/icon_256.png" "${STAGE}/ICON_256.PNG"

# ── 6. 自检 ──────────────────────────────────────────────────
if grep -rn -e '{port}' -e '{display_name}' "${APP_DIR}/ui" > /dev/null 2>&1; then
    echo "✗ ui/ 里仍有 {port} / {display_name} 占位符 → 桌面图标会点了没反应"
    exit 1
fi
if [ "${HERMES_USE_SYSTEM_PYTHON:-0}" = "1" ]; then
    [ -f "${RT}/.use-system-python" ] || { echo "✗ 系统 Python 模式缺标记文件"; exit 1; }
    [ -f "${RT}/deps.txt" ] || { echo "✗ 系统 Python 模式缺依赖清单 runtime/deps.txt"; exit 1; }
else
    [ -d "${RT}/python/lib" ] || { echo "✗ 缺 Python 标准库目录"; exit 1; }
fi
[ -f "${RT}/deps.txt" ] || { echo "✗ 缺依赖清单 runtime/deps.txt"; exit 1; }

# ── 7. manifest / cmd / config / wizard ─────────────────────
echo "[build] 写 manifest"
sed -e "s/^version  *=.*/version               = ${VERSION}/" \
    -e "s/^platform  *=.*/platform              = ${MANIFEST_PLATFORM}/" \
    "${PKG_DIR}/manifest" > "${STAGE}/manifest"

cp -r "${PKG_DIR}/cmd"    "${STAGE}/cmd"
cp -r "${PKG_DIR}/config" "${STAGE}/config"
cp -r "${PKG_DIR}/wizard" "${STAGE}/wizard"
chmod 755 "${STAGE}/cmd/"*

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

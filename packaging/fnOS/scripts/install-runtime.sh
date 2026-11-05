#!/bin/bash
# Hermes 运行期安装 —— 由 cmd/install_callback 与 cmd/main 共用。
#
# 为什么需要：本包不再预置 Python / 依赖 / 源码，全部在这里获取，
# 让上游 PM 用【真实 venv】管理依赖环境（与官方 scripts/install.sh 一致）。
#
# 流程：
#   1. ensure_uv          锁定版本 + sha256 校验 + 镜像回退
#   2. install_source     git clone --filter=blob:none（保留 .git → 支持 hermes update）
#   3. bootstrap_python   从 <src>/pm/lock.json 读版本，uv python find/install
#   4. pm_install         boot_py -m pm.cli install --extra web --extra messaging
#
# 用法：
#   install-runtime.sh <data_dir> <app_dir> [--source-only]
#
# 环境变量（由调用方设置）：
#   HERMES_REF           上游 ref（tag 或分支），默认 v0.22.5
#   HERMES_PYPI_INDEX    PyPI 源；非空则覆盖
#   HERMES_GH_MIRROR     GitHub 加速前缀（如 https://gh-proxy.com/）
#   代理变量（HTTP_PROXY 等）由调用方 export，本脚本不处理

set -uo pipefail

DATA_DIR="${1:?缺少 data_dir}"
APP_DIR="${2:?缺少 app_dir}"
MODE="${3:-full}"

SRC="${DATA_DIR}/src"
LOG="${DATA_DIR}/log/install-runtime.log"
UV_STORE="${DATA_DIR}/tools"
UV_VER="0.13.5"
HERMES_REF="${HERMES_REF:-v0.22.5}"
REPO="NousResearch/hermes-agent"

mkdir -p "${DATA_DIR}/log" "${UV_STORE}"

log() { printf '%s\n' "$*" | tee -a "${LOG}"; }
die() { log "✗ $*"; exit 1; }

# ── 工具 ─────────────────────────────────────────────────────
have() { command -v "$1" > /dev/null 2>&1; }

sha256_of() {
    if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# ── 下载策略 ─────────────────────────────────────────────────
#
# 用户要求：不要卡在 10KB/s 上耗时间；该走镜像走镜像、该走代理走代理。
#
#   · 配了代理   → 只走原地址（curl 自动用 HTTP(S)_PROXY）。
#                  镜像会再套一层代理，更慢且更容易失败。
#   · 没配代理   → 直连 + GitHub 镜像【并行竞速】，谁先下完用谁。
#   · 任何单路   → 20 秒内平均低于 20KB/s 判定龟速，主动放弃转下一源。
#
# 竞速判定：每源先写 .part，完成后原子 mv → 正式名存在即「已完成」。

# 下载到 <out>.part，成功后原子 mv 到 <out>。
# ⚠ 竞速模式靠「<out> 是否存在」判断【已完成】；直接写 <out> 会在下载中途
#   就被误判成功（拿到半截文件），所以必须先写 .part 再 mv。
_dl_one() {  # $1 输出 $2 URL
    local out="$1" url="$2"
    rm -f "${out}.part"
    local rc=1
    if have curl; then
        curl -fsSL --retry 1 --connect-timeout 15 --max-time 1800              --speed-limit 20480 --speed-time 20              -o "${out}.part" "${url}" 2>>"${LOG}"
        rc=$?
    elif have wget; then
        wget -q --timeout=20 --tries=2 -O "${out}.part" "${url}" 2>>"${LOG}"
        rc=$?
    fi
    if [ "${rc}" -eq 0 ] && [ -s "${out}.part" ]; then
        mv "${out}.part" "${out}"
        return 0
    fi
    rm -f "${out}.part"
    return 1
}

# fetch <目标> <原始URL>
fetch() {
    local out="$1" url="$2"
    if [ -n "${HTTPS_PROXY:-}${HTTP_PROXY:-}" ]; then
        log "  下载（代理）: ${url}"
        rm -f "${out}"
        _dl_one "${out}" "${url}"
        [ -s "${out}" ] && return 0
        rm -f "${out}"
        return 1
    fi

    # 候选源
    local -a urls=("${url}")
    case "${url}" in
        https://github.com/*|https://codeload.github.com/*)
            [ -n "${HERMES_GH_MIRROR:-}" ] && urls+=("${HERMES_GH_MIRROR%/}/${url}")
            urls+=("https://gh-proxy.com/${url}" "https://ghproxy.net/${url}")
            ;;
    esac

    if [ "${#urls[@]}" -eq 1 ]; then
        log "  下载: ${url}"
        rm -f "${out}"
        _dl_one "${out}" "${url}"
        [ -s "${out}" ] && return 0
        rm -f "${out}"
        return 1
    fi

    # 并行竞速
    local tmpd; tmpd="$(mktemp -d)"
    local -a pids=()
    local i=0 u
    for u in "${urls[@]}"; do
        i=$((i + 1))
        log "  竞速#${i}: ${u}"
        _dl_one "${tmpd}/r${i}" "${u}" &
        pids+=($!)
    done
    # 轮询等待第一个成功的（最多 1800 秒）
    local waited=0 winner=""
    while [ "${waited}" -lt 1800 ]; do
        for i in $(seq 1 "${#urls[@]}"); do
            if [ -s "${tmpd}/r${i}" ]; then
                winner="${tmpd}/r${i}"; break
            fi
        done
        [ -n "${winner}" ] && break
        # 全部进程都已退出且没有赢家 → 失败
        local alive=0 p
        for p in "${pids[@]}"; do kill -0 "${p}" 2>/dev/null && alive=$((alive + 1)); done
        [ "${alive}" -eq 0 ] && break
        sleep 1
        waited=$((waited + 1))
    done
    local p
    for p in "${pids[@]}"; do kill "${p}" 2>/dev/null || true; done
    wait 2>/dev/null || true

    if [ -n "${winner}" ]; then
        mv "${winner}" "${out}"
        rm -rf "${tmpd}"
        return 0
    fi
    rm -rf "${tmpd}"
    return 1
}

# ── 1. uv ────────────────────────────────────────────────────
ensure_uv() {
    local entry="${UV_STORE}/uv-${UV_VER}-linux-x64"
    local bin="${entry}/uv"
    if [ -x "${bin}" ] && "${bin}" --version > /dev/null 2>&1; then
        log "✓ uv 已存在: $("${bin}" --version)"
        UV="${bin}"; return 0
    fi
    local url="https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-x86_64-unknown-linux-gnu.tar.gz"
    local tmp; tmp="$(mktemp -d)"
    log "获取 uv ${UV_VER}…"
    fetch "${tmp}/uv.tar.gz" "${url}" || { rm -rf "${tmp}"; die "uv 下载失败（可填写代理后重试）"; }

    # 校验（哈希与上游 install.sh 一致）
    local want="f68d291c75783122dad58ab77def0e13f3233f358731db5d6d7e8715603b928f"
    local got; got="$(sha256_of "${tmp}/uv.tar.gz")"
    if [ "${got}" != "${want}" ]; then
        rm -rf "${tmp}"
        die "uv 校验失败（期望 ${want}，实际 ${got}）—— 可能是镜像返回了错误内容"
    fi

    tar -xzf "${tmp}/uv.tar.gz" -C "${tmp}" || { rm -rf "${tmp}"; die "uv 解压失败"; }
    local unpacked; unpacked="$(find "${tmp}" -mindepth 1 -maxdepth 2 -name uv -type f | head -n1)"
    [ -n "${unpacked}" ] || { rm -rf "${tmp}"; die "压缩包里找不到 uv"; }
    mkdir -p "${entry}"
    mv "${unpacked}" "${bin}"
    [ -f "$(dirname "${unpacked}")/uvx" ] && mv "$(dirname "${unpacked}")/uvx" "${entry}/uvx" 2>/dev/null
    chmod +x "${bin}" "${entry}/uvx" 2>/dev/null || true
    rm -rf "${tmp}"
    "${bin}" --version > /dev/null 2>&1 || die "uv 下载后无法运行"
    UV="${bin}"
    log "✓ uv $("${bin}" --version)"
}

# ── 2. 源码 ──────────────────────────────────────────────────
# 优先 git clone（保留 .git → sealed_steward() 返回 None → 允许 hermes update）
install_source() {
    if [ -d "${SRC}/.git" ] && git -C "${SRC}" rev-parse --verify HEAD > /dev/null 2>&1; then
        log "✓ 源码已存在: ${SRC} ($(git -C "${SRC}" rev-parse --short HEAD))"
        return 0
    fi
    # 有残留但不是可用 git checkout → 挪开（不删，可能是用户的东西）
    if [ -e "${SRC}" ]; then
        local bak="${SRC}.broken-$(date -u +%Y%m%d-%H%M%S)"
        log "⚠ ${SRC} 不是可用的 git checkout，移到 ${bak}"
        mv "${SRC}" "${bak}" || die "无法移开 ${SRC}"
    fi
    mkdir -p "$(dirname "${SRC}")"

    if have git; then
        log "git clone ${REPO}@${HERMES_REF}…"
        local urls=("https://github.com/${REPO}.git")
        [ -n "${HERMES_GH_MIRROR:-}" ] && urls+=("${HERMES_GH_MIRROR%/}/https://github.com/${REPO}.git")
        urls+=("https://gh-proxy.com/https://github.com/${REPO}.git")
        local u
        for u in "${urls[@]}"; do
            log "  尝试: ${u}"
            if git clone --filter=blob:none --depth 1 --branch "${HERMES_REF}" \
                   "$u" "${SRC}" >> "${LOG}" 2>&1; then
                log "✓ 源码就绪（git，支持在线更新）"
                return 0
            fi
            rm -rf "${SRC}"
        done
        log "⚠ git clone 全部失败，回退 tarball（将失去 hermes update）"
    else
        log "⚠ 系统没有 git，使用 tarball（将失去 hermes update）"
    fi

    # 回退：tarball（无 .git）
    local tmp; tmp="$(mktemp -d)"
    local tars=("https://codeload.github.com/${REPO}/tar.gz/refs/tags/${HERMES_REF}")
    [ -n "${HERMES_GH_MIRROR:-}" ] && tars+=("${HERMES_GH_MIRROR%/}/https://github.com/${REPO}/archive/refs/tags/${HERMES_REF}.tar.gz")
    tars+=("https://gh-proxy.com/https://github.com/${REPO}/archive/refs/tags/${HERMES_REF}.tar.gz")
    local t
    for t in "${tars[@]}"; do
        if fetch "${tmp}/src.tgz" "$t"; then
            mkdir -p "${SRC}"
            tar -xzf "${tmp}/src.tgz" -C "${SRC}" --strip-components=1 || continue
            rm -rf "${tmp}"
            echo "${HERMES_REF}" > "${SRC}/.tarball-ref"
            log "✓ 源码就绪（tarball）"
            return 0
        fi
    done
    rm -rf "${tmp}"
    die "源码获取失败（git 与 tarball 都不可用）"
}

# ── 3. bootstrap Python ──────────────────────────────────────
# 版本来自 <src>/pm/lock.json，不由本脚本写死 —— 上游更新时自动跟随。
bootstrap_python() {
    local lock="${SRC}/pm/lock.json"
    [ -f "${lock}" ] || die "缺少 ${lock}"

    local pyver
    pyver="$(awk -F '"' '
        /^[[:space:]]*("[^"]+"[[:space:]]*:[[:space:]]*)?\{/ { path[++depth] = $2; next }
        /^[[:space:]]*\}[[:space:]]*,?[[:space:]]*$/ { delete path[depth--]; next }
        path[2] == "packages" && path[3] == "python" && $2 == "version" && depth == 3 { print $4; exit }
    ' "${lock}" | cut -d+ -f1 | cut -d. -f1,2)"
    [ -n "${pyver}" ] || pyver="3.14"
    log "PM 需要 Python ${pyver}（来自 pm/lock.json）"

    local py
    if py="$(UV_SYSTEM_PYTHON=1 UV_NO_PROJECT=1 "${UV}" python find --managed-python "${pyver}" 2>>"${LOG}")"; then
        log "✓ 复用已有 Python: ${py}"
    elif py="$("${UV}" python find --system --no-project "${pyver}" 2>>"${LOG}")"; then
        log "✓ 使用系统 Python: ${py}"
    else
        log "下载 Python ${pyver}…"
        UV_PYTHON_INSTALL_DIR="${DATA_DIR}/pythons" \
            "${UV}" python install --no-bin --no-registry "${pyver}" >> "${LOG}" 2>&1 \
            || die "Python 下载失败（可填写代理后重试）"
        py="$(UV_SYSTEM_PYTHON=1 UV_NO_PROJECT=1 UV_PYTHON_INSTALL_DIR="${DATA_DIR}/pythons" \
              "${UV}" python find --managed-python "${pyver}")" || die "Python 安装后找不到"
        log "✓ Python 已下载: ${py}"
    fi
    py="${py%$'\r'}"
    [ -x "${py}" ] || die "Python 不可执行: ${py}"
    BOOT_PY="${py}"
}

# ── 4. pm install ────────────────────────────────────────────
pm_install() {
    # extras 以 <data>/enabled-features.json 为准（install_callback 已写好），
    # 环境变量 PM_EXTRAS 可覆盖。避免两处各写一份清单。
    local extras="${PM_EXTRAS:-}"
    if [ -z "${extras}" ]; then
        local feat="${DATA_DIR}/enabled-features.json"
        if [ -r "${feat}" ] && [ -n "${BOOT_PY:-}" ]; then
            extras="$("${BOOT_PY}" - "${feat}" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
except (OSError, ValueError):
    raise SystemExit(0)
ex = d.get("extras")
if isinstance(ex, list):
    print(" ".join(str(e) for e in ex if str(e).strip()))
PY
)"
        fi
    fi
    [ -n "${extras}" ] || extras="web messaging"
    # "all" 对我们没意义（会装全量，体积爆炸）
    extras="$(printf '%s' "${extras}" | tr ' ' '\n' | grep -vx 'all' | tr '\n' ' ')"
    extras="${extras% }"
    log "extras: ${extras}"
    local args=(install)
    local e
    for e in ${extras}; do args+=(--extra "$e"); done

    log "执行 pm ${args[*]}…"
    # ⚠ 关键：显式把系统目录放进 PATH。
    #
    # 实机 2026-11-05 定位：安装回调由 appcenter 拉起，PATH 可能与运行期
    # 进程不同（可能缺 /usr/bin）。而 pm/workspace.py 会剥掉
    # [tool.uv] exclude-newer → uv 判定 lock 过期 → 重新做 universal 解析
    # → 必须拉 android 专用的 psutil git 依赖 → 需要 git。
    # git 不在 PATH 里时的报错是「Git executable not found」，与线上逐字一致。
    #
    # 这里保证 /usr/local/bin:/usr/bin:/bin 一定在 PATH 前部（系统 git/node 在这）。
    local syspath="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    local curpath="${PATH:-}"
    case ":${curpath}:" in
        *":/usr/bin:"*) : ;;                      # 已有，不重复加
        *) curpath="${syspath}${curpath:+:${curpath}}" ;;
    esac
    log "PATH(交给 pm)=${curpath}"
    log "git=$(command -v git 2>/dev/null || echo '<未找到>')"

    # 用数组传环境变量，避免 URL 含空格时被分词
    local -a envs=(
        "HOME=${DATA_DIR}"
        "PATH=${curpath}"
        "UV_CACHE_DIR=${DATA_DIR}/.uv-cache"
        "UV_PYTHON_INSTALL_DIR=${DATA_DIR}/pythons"
        "PYTHONPATH=${SRC}"
        "HERMES_HOME=${DATA_DIR}"
    )
    if [ -n "${HERMES_PYPI_INDEX:-}" ]; then
        envs+=("UV_DEFAULT_INDEX=${HERMES_PYPI_INDEX}")
        envs+=("PIP_INDEX_URL=${HERMES_PYPI_INDEX}")
        envs+=("UV_INDEX_URL=${HERMES_PYPI_INDEX}")
    fi
    log "PyPI 源: ${HERMES_PYPI_INDEX:-默认}"
    (
        cd "${SRC}" || exit 1
        env "${envs[@]}" "${BOOT_PY}" -m pm.cli "${args[@]}"
    ) >> "${LOG}" 2>&1 || die "pm install 失败，详见 ${LOG}"
    log "✓ 依赖环境已就绪"

    ### 回收旧 generation：每次 sync 会新建 ~440MB 的环境目录，旧的不自动删
    ### （实机 2026-11-05：3 代共存 1.3G）。上游 `pm gc` 会清理
    ### 「非 selected 且已满 24h 冷静期」的 generation —— 冷静期内的保留，
    ### 这是上游防止误删正在使用的环境的保守设计，我们尊重它。
    ### 失败不影响安装结果（只是磁盘清理）。
    log "清理旧依赖环境（24h 内的会保留）…"
    (
        cd "${SRC}" || exit 1
        env "${envs[@]}" "${BOOT_PY}" -m pm.cli gc
    ) >> "${LOG}" 2>&1 || log "⚠ pm gc 未成功（不影响使用）"
}

# ── 5. 校验 ──────────────────────────────────────────────────
verify() {
    local facts
    facts="$(find "${DATA_DIR}/installs" -maxdepth 2 -name facts.json -type f \
               -not -path '*.disabled-*' 2>/dev/null | head -n 1)"
    [ -n "${facts}" ] || die "pm install 后仍未找到 facts.json"

    local venv
    venv="$("${BOOT_PY}" - "${facts}" <<'PY'
import json, sys
from pathlib import Path
d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
env = ((d.get("packages") or {}).get("venv") or {}).get("environment")
print(env if isinstance(env, str) else "")
PY
)"
    [ -n "${venv}" ] || die "facts.json 里没有 environment"
    local py="${venv}/bin/python3"
    [ -x "${py}" ] || die "venv 解释器不存在: ${py}"

    "${py}" -c "import fastapi, uvicorn, aiohttp, PIL, cryptography, psutil" \
        || die "关键依赖导入失败"
    log "✓ 校验通过: ${venv}"
    VENV_PY="${py}"
}

# ── main ─────────────────────────────────────────────────────
log "=== install-runtime $(date -Is) mode=${MODE} ==="

### 幂等：PM 环境已就绪且源码存在 → 直接返回，不重复下载/安装。
### 升级或重装时这能省掉几分钟。
### 环境是否【属于当前源码】且可用。
### ⚠ 必须校验 key 匹配，不能只看「有个能用的 venv」：
###   install_key = sha256(源码绝对路径)[:16]。旧布局源码在包内
###   (<appcenter>/runtime/hermes)，新布局在 <data>/src —— key 不同。
###   只判断「有 venv」会命中旧环境 → 幂等跳过 → 新源码下无法运行。
pm_env_ok() {
    [ -d "${SRC}/hermes_cli" ] || return 1
    local boot=""
    boot="$(command -v python3 2>/dev/null)" || return 1
    local want_key
    want_key="$("${boot}" -c \
        "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])" "${SRC}" 2>/dev/null || true)"
    [ -n "${want_key}" ] || return 1

    local facts="${DATA_DIR}/installs/${want_key}/facts.json"
    [ -f "${facts}" ] || return 1

    # 要求 extras 覆盖 enabled-features.json 的基线，否则视为需重装。
    # ⚠ 这条必须有：实机 2026-11-05 升级时只查了「venv 可用」→ 跳过安装
    #   → 基线从 computer-use/wake 收窄成 web+messaging 后，MCP 等模块从此缺失，
    #   而幂等检查永远认为「已就绪」，再也不会补装。
    local feat="${DATA_DIR}/enabled-features.json"
    "${boot}" - "${facts}" "${feat}" <<'PY' 2>/dev/null
import json, sys
from pathlib import Path
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
except (OSError, ValueError):
    raise SystemExit(1)
env = ((d.get("packages") or {}).get("venv") or {}).get("environment")
if not isinstance(env, str) or not env:
    raise SystemExit(1)
if not (Path(env) / "bin" / "python3").is_file():
    raise SystemExit(1)
have = {str(e).lower() for e in (((d.get("packages") or {}).get("venv") or {}).get("extras") or [])}
if "all" in have:
    raise SystemExit(0)
want = set()
try:
    feat = json.load(open(sys.argv[2], encoding="utf-8-sig"))
    if isinstance(feat.get("extras"), list):
        want = {str(e).lower() for e in feat["extras"] if str(e).strip()}
except (OSError, ValueError, AttributeError):
    pass
missing = want - have
if missing:
    print("missing extras: " + ",".join(sorted(missing)), file=sys.stderr)
    raise SystemExit(1)
raise SystemExit(0)
PY
    return $?
}

if [ "${MODE}" != "--force" ] && pm_env_ok; then
    log "✓ 运行期已就绪（PM 环境 + 源码），跳过安装"
    # 环境虽就绪，旧 generation 仍需要回收（24h 冷静期过后才会被删，
    # 但 pm gc 必须有人调 —— 只在"真安装"时调的话，日常重启永远清不到）。
    # 静默执行：失败无关紧要，别刷日志。
    if [ -n "${BOOT_PY:-}" ] || boot_py="$(command -v python3 2>/dev/null)"; then
        (
            cd "${SRC}" 2>/dev/null && \
            env HOME="${DATA_DIR}" UV_CACHE_DIR="${DATA_DIR}/.uv-cache" \
                UV_PYTHON_INSTALL_DIR="${DATA_DIR}/pythons" PYTHONPATH="${SRC}" \
                HERMES_HOME="${DATA_DIR}" \
                "${boot_py}" -m pm.cli gc
        ) >> "${LOG}" 2>&1 || true
    fi
    log "=== 完成 $(date -Is)（幂等跳过）==="
    exit 0
fi

### 归档「不属于当前源码」的旧 PM 环境。
### 为什么放在这里而不是 upgrade_callback：安装失败会中止升级流程，
### upgrade_callback 根本不会被调用（实机 2026-11-05 的 upgrade.log 只有
### upgrade_init，没有 upgrade_callback），旧环境就一直留着。
### 放在真正执行安装的脚本里，无论从哪条路径进来都能收敛。
archive_stale_envs() {
    [ -d "${DATA_DIR}/installs" ] || return 0
    local want_key
    want_key="$( (command -v python3 >/dev/null 2>&1 && python3 -c         "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])" "${SRC}") 2>/dev/null || true)"
    [ -n "${want_key}" ] || { log "⚠ 无法计算 install key，跳过旧环境归档"; return 0; }
    local arch="${DATA_DIR}/installs.archived-$(date +%Y%m%d-%H%M%S)" moved=0 d name
    for d in "${DATA_DIR}/installs"/*/; do
        [ -d "${d}" ] || continue
        name="$(basename "${d%/}")"
        case "${name}" in
            *.disabled-*) continue ;;      # 历史归档，不动
            "${want_key}") continue ;;     # 当前 key，保留
        esac
        mkdir -p "${arch}" 2>/dev/null || true
        if mv "${d%/}" "${arch}/${name}" 2>/dev/null; then moved=$((moved + 1)); fi
    done
    if [ "${moved}" -gt 0 ]; then
        log "已归档 ${moved} 个旧 PM 环境 → ${arch}（当前 key=${want_key}）"
    fi
}
archive_stale_envs

ensure_uv
install_source
[ "${MODE}" = "--source-only" ] && { log "仅源码模式，结束"; exit 0; }
bootstrap_python
pm_install
verify
log "=== 完成 $(date -Is) ==="

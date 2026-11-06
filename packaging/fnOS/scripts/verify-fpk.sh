#!/usr/bin/env bash
#
# 校验单个 fpk 产物 —— 按档位（A=在线版 / B=预置版）分支断言
# ============================================================
# 用法：
#   bash packaging/fnOS/scripts/verify-fpk.sh <path/to/hermes-xxx.fpk> <A|B>
#
# 为什么单独成脚本：
#   · CI 里原本把断言内联在 build.yml，两个档位硬绑在一起 —— 单独验证 B 时
#     会被"必须同时存在 A"挡住，无法只跑 B。
#   · 抽出来后本地也能对下载的 fpk 复验，不必重跑整个构建。
#
# 档位差异（这是本脚本存在的核心价值）：
#   A 版：不预置运行时 → 体积 <110MB，且【不得】含 python.tar.gz / wheelhouse
#   B 版：预置 Python + wheelhouse → 体积 <260MB，且【必须】含三者，
#         其中 wheelhouse 里的 Pillow 必须是 13.0.0（browser-harness 声明
#         pillow==12.3.0，靠 uv override 才能上 13；若 pip download 又按
#         传递依赖解析，就会退回 12.x 或直接失败 —— 实机 2026-11-05 踩过）
#
# ⚠ 断言一律用 `grep ... <<<"$VAR"`（here-string），不要 `echo "$VAR" | grep`。
#   后者在 grep -q 命中后提前退出，echo 收到 SIGPIPE，在 set -o pipefail 下
#   被当成失败 → 断言误报"缺少 xxx"（CI 2026-11-06 实测，$A 变大后必现）。

set -euo pipefail

FPK="${1:-}"
PRESET="${2:-}"

[ -n "${FPK}" ] || { echo "用法：$0 <fpk 路径> <A|B>"; exit 2; }
[ -f "${FPK}" ] || { echo "✗ 文件不存在：${FPK}"; exit 1; }
case "${PRESET}" in
    A|B) ;;
    *) echo "✗ 档位必须是 A 或 B（收到：'${PRESET}'）"; exit 2 ;;
esac

SIZE=$(stat -c%s "${FPK}")
echo "── 档位 ${PRESET}：${FPK} ($(du -h "${FPK}" | cut -f1)) ──"
LIST="$(tar -tzf "${FPK}")"

### 断言收集器：失败不立即退出，先记下来继续跑完，最后统一汇总。
### 为什么：CI 一次只能看到【第一条】失败，改一版跑一次，来回好几轮。
### 全跑完再报，一次就能看全。
FAILS=()
fail() { FAILS+=("$*"); echo "✗ $*"; }
ok()   { echo "✓ $*"; }
finish() {
    if [ "${#FAILS[@]}" -gt 0 ]; then
        echo
        echo "✗ 档位 ${PRESET} 校验失败，共 ${#FAILS[@]} 项："
        local i=1 f
        for f in "${FAILS[@]}"; do echo "   $i) $f"; i=$((i + 1)); done
        exit 1
    fi
    echo "✓ 档位 ${PRESET} 校验通过"
    exit 0
}

# ── 顶层结构 ──────────────────────────────────────────────
for need in manifest ICON.PNG ICON_256.PNG app.tgz \
            cmd/main cmd/install_callback cmd/config_callback cmd/uninstall_callback \
            config/privilege config/resource \
            wizard/install wizard/config wizard/uninstall; do
    grep -qx -- "$need" <<<"${LIST}" || fail "fpk 顶层缺少 ${need}"
done

X="$(mktemp -d)"
trap 'rm -rf "${X}"' EXIT
tar -xzf "${FPK}" -C "${X}" app.tgz manifest cmd/main cmd/install_callback \
                   wizard/install wizard/config
A="$(tar -tzf "${X}/app.tgz")"

# ── app.tgz 必须含的安装期组件 ────────────────────────────
for need in ./scripts/install-runtime.sh ./gateway-proxy.py ./envfile.sh \
            ./ui/config ./bin/hermes ./runtime/web_dist/index.html \
            ./runtime/install-stamp.json ./upstream-ref; do
    grep -qx -- "$need" <<<"${A}" || fail "app.tgz 缺少 ${need}"
done

# ── app.tgz 不得包含的东西（两档都必须在安装期获取）──────
if grep -qE '^\./runtime/(python|hermes)/' <<<"${A}"; then
    fail "app.tgz 仍含 runtime/python 或源码树"
fi
if grep -qx -- './runtime/deps.txt' <<<"${A}"; then
    fail "app.tgz 仍含 deps.txt"
fi
if grep -qx -- './hermes-update.py' <<<"${A}"; then
    fail "app.tgz 仍含 hermes-update.py（已改用上游 hermes update）"
fi

# ── desktop bundle（浏览器版工作区）──────────────────────────
# 预置了它，装机后无需联网 npm 构建即可从飞牛桌面打开 desktop。
# 上游 < v0.22.6 没有 webapp 能力，此时允许缺失（cmd/main 会自动退回 dashboard）。
# ⚠ 必须预置：本包的门户默认指向 desktop，没有 bundle 就等于退回 dashboard，
#   与"默认进 desktop"的需求不符。上游 v0.22.7 已带 webapp，构建期必须产出它。
if grep -q '^\./runtime/webapp_dist/index\.html$' <<<"${A}"; then
    grep -q '^\./runtime/webapp_dist/assets/' <<<"${A}" \
        || fail "webapp_dist 缺 assets/（bundle 不完整）"
    ok "desktop bundle 已预置"
else
    fail "未预置 desktop bundle（runtime/webapp_dist/index.html）—— 门户将退回 dashboard"
fi

# ── manifest 关键字段 ─────────────────────────────────────
grep -q '^service_port[[:space:]]*=[[:space:]]*9119' "${X}/manifest" \
    || fail "manifest 缺少 service_port = 9119"
grep -q '^checkport[[:space:]]*=[[:space:]]*true' "${X}/manifest" \
    || fail "manifest 缺少 checkport"
# 应用信息：发布者仍是 soul87，其余归 Hermes 官方
grep -qE '^developer[[:space:]]*=[[:space:]]*Hermes[[:space:]]*$' "${X}/manifest" \
    || fail "manifest 的 developer 应为 Hermes（官方）"
grep -qE '^maintainer[[:space:]]*=[[:space:]]*Hermes[[:space:]]*$' "${X}/manifest" \
    || fail "manifest 的 maintainer 应为 Hermes（官方；fnOS 把它显示为「开发者」）"
grep -qE '^distributor[[:space:]]*=[[:space:]]*soul87' "${X}/manifest" \
    || fail "manifest 的 distributor 应为 soul87（发布者保持不变）"

# ── 向导字段 ──────────────────────────────────────────────
for f in wizard/install wizard/config; do
    grep -q 'wizard_auth_password' "${X}/${f}" \
        || fail "${f} 缺少面板密码字段"
    grep -q 'wizard_webapp_port_access' "${X}/${f}" \
        || fail "${f} 缺少 desktop 端口访问开关"
    grep -q 'wizard_dash_port_access' "${X}/${f}" \
        || fail "${f} 缺少 dashboard 端口访问开关"
done

# ── cmd/main 关键机制 ─────────────────────────────────────
# 统一网关默认指向 desktop：上游端口由 gateway_upstream_port 决定
grep -q 'gateway_upstream_port' "${X}/cmd/main" \
    || fail "cmd/main 缺少 gateway_upstream_port（网关未指向 desktop）"
# desktop bundle 经 HERMES_WEBAPP_DIST 指向上游（上游据此永不重建）
grep -q 'HERMES_WEBAPP_DIST' "${X}/cmd/main" \
    || fail "cmd/main 未把 HERMES_WEBAPP_DIST 传给 gateway"
# 凭据文件：gateway 也要 source，否则 desktop 登录必 401
grep -q 'AUTH_ENV_FILE' "${X}/cmd/main" \
    || fail "cmd/main 缺少凭据文件机制"
grep -q 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD' "${X}/cmd/main" \
    || fail "cmd/main 未注入 basic auth"
grep -q 'envfile.sh' "${X}/cmd/main" \
    || fail "cmd/main 未加载 envfile.sh"
grep -q 'install-runtime.sh' "${X}/cmd/install_callback" \
    || fail "install_callback 未调用 install-runtime.sh"

# ── 关键：补丁必须已删除（防止回退到旧实现）──────────────
for fn in ensure_pm_env_ignored lazy_prune_redundant pm_bootstrap_kick \
          migrate_pm_venv_extras ensure_lazy_site_abi; do
    if grep -q "^${fn}() {" "${X}/cmd/main"; then
        fail "cmd/main 仍含旧补丁 ${fn}"
    fi
done
grep -q 'pm_venv_python()' "${X}/cmd/main" \
    || fail "cmd/main 缺少 pm_venv_python"
ok "补丁已清除，改用 PM 真实 venv"

# ── web_dist 前缀别名（端口直连白屏修复）──────────────────
LINKS="$(tar -tvzf "${X}/app.tgz" | grep 'runtime/web_dist/app/hermes' || true)"
if grep -q '^l' <<<"${LINKS}"; then
    ok "web_dist 前缀别名存在"
else
    fail "web_dist 缺少 app/hermes 软链"
fi

# ── 档位专属断言 ──────────────────────────────────────────
if [ "${PRESET}" = "A" ]; then
    # 在线版不预置运行时；但含两个预构建前端：
    #   web_dist（dashboard，~10MB）+ webapp_dist（desktop，~37MB）
    # 故上限放到 110MB。超过说明又把 python/wheelhouse 打包进来了。
    if [ "${SIZE}" -gt 115343360 ]; then
        fail "在线版体积 $(du -h "${FPK}" | cut -f1) 超过 110MB —— 疑似又把运行时打包进去了"
    fi
    # 反向断言：A 版绝不能预置这些（预置了就说明 preset 判断失效）
    for f in ./runtime/python.tar.gz ./runtime/requirements.lock; do
        if grep -qx -- "$f" <<<"${A}"; then
            fail "在线版不应含 ${f}（preset 判断可能失效）"
        fi
    done
    if grep -q '^\./runtime/wheelhouse/' <<<"${A}"; then
        fail "在线版不应含 wheelhouse（preset 判断可能失效）"
    fi
    ok "档位 A：未预置运行时，体积 $(du -h "${FPK}" | cut -f1)（上限 110MB）"
else
    # ── B 版：预置 Python + wheelhouse ──
    if [ "${SIZE}" -gt 272629760 ]; then
        fail "档位B 体积 $(du -h "${FPK}" | cut -f1) 超过 260MB —— wheelhouse/Python 预置异常膨胀"
    fi
    for need in ./runtime/python.tar.gz ./runtime/requirements.lock; do
        grep -qx -- "$need" <<<"${A}" || fail "档位B 缺少 ${need}"
    done
    if ! grep -q '^\./runtime/wheelhouse/' <<<"${A}"; then
        fail "档位B 缺少 runtime/wheelhouse/"
    fi

    # 真正解出 wheelhouse 看内容 —— 这是 Pillow 冲突修复的回归守卫。
    if tar -xzf "${X}/app.tgz" -C "${X}" ./runtime/wheelhouse ./runtime/requirements.lock 2>/dev/null; then
        WH="${X}/runtime/wheelhouse"
        NW=$(ls "${WH}" 2>/dev/null | wc -l)
        if [ "${NW}" -eq 0 ]; then
            fail "wheelhouse 为空"
        else
            # Pillow 必须是 13.0.0：browser-harness 0.1.13 元数据精确 pin 12.3.0，
            # 能共存全靠 uv override。若 pip 又按传递依赖解析 → 冲突或退回 12.x。
            if ls "${WH}" | grep -qiE '^pillow-12\.'; then
                fail "wheelhouse 含 Pillow 12.x —— override 失效（应只有 13.0.0）"
            fi
            ls "${WH}" | grep -qiE '^pillow-13\.0\.0-' \
                || fail "wheelhouse 缺 Pillow 13.0.0"
            # 抽样：关键 wheel 不得缺失（漏了会在装机期才炸）
            for pat in 'browser_harness' 'cbor2' 'websockets'; do
                ls "${WH}" | grep -qi "^${pat}-" || fail "wheelhouse 缺 ${pat}"
            done
            ok "Pillow 13.0.0 已入 wheelhouse（override 生效，未退回 12.x）"
            ok "档位B：wheelhouse ${NW} 个 wheel，$(du -sh "${WH}" | cut -f1)"
        fi
    else
        fail "解包 wheelhouse 失败"
    fi
fi

finish

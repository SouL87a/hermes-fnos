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

# ── 顶层结构 ──────────────────────────────────────────────
for need in manifest ICON.PNG ICON_256.PNG app.tgz \
            cmd/main cmd/install_callback cmd/config_callback cmd/uninstall_callback \
            config/privilege config/resource \
            wizard/install wizard/config wizard/uninstall; do
    echo "$LIST" | grep -qx "$need" || { echo "✗ fpk 顶层缺少 $need"; exit 1; }
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
    echo "$A" | grep -qx "$need" || { echo "✗ app.tgz 缺少 $need"; exit 1; }
done

# ── app.tgz 不得包含的东西（两档都必须在安装期获取）──────
if echo "$A" | grep -qE '^\./runtime/(python|hermes)/'; then
    echo "✗ app.tgz 仍含 runtime/python 或源码树"; exit 1
fi
if echo "$A" | grep -qx './runtime/deps.txt'; then
    echo "✗ app.tgz 仍含 deps.txt"; exit 1
fi
if echo "$A" | grep -qx './hermes-update.py'; then
    echo "✗ app.tgz 仍含 hermes-update.py（已改用上游 hermes update）"; exit 1
fi

# ── desktop bundle（浏览器版工作区）──────────────────────────
# 预置了它，装机后无需联网 npm 构建即可从飞牛桌面打开 desktop。
# 上游 < v0.22.6 没有 webapp 能力，此时允许缺失（cmd/main 会自动退回 dashboard）。
if echo "$A" | grep -q '^\./runtime/webapp_dist/index\.html$'; then
    echo "$A" | grep -q '^\./runtime/webapp_dist/assets/' \
        || { echo "✗ webapp_dist 缺 assets/（bundle 不完整）"; exit 1; }
    echo "✓ desktop bundle 已预置"
else
    echo "⚠ 未预置 desktop bundle（上游可能 < v0.22.6）→ 桌面图标将退回 dashboard"
fi

# ── 关键配置断言 ──────────────────────────────────────────
grep -q '^service_port[[:space:]]*=[[:space:]]*9119' "${X}/manifest" \
    || { echo "✗ manifest 缺少 service_port = 9119"; exit 1; }
grep -q '^checkport[[:space:]]*=[[:space:]]*true' "${X}/manifest" \
    || { echo "✗ manifest 缺少 checkport"; exit 1; }
for f in wizard/install wizard/config; do
    grep -q 'wizard_auth_password' "${X}/${f}" \
        || { echo "✗ ${f} 缺少面板密码字段"; exit 1; }
    # 端口访问开关（desktop / dashboard 各一个）
    grep -q 'wizard_webapp_port_access' "${X}/${f}" \
        || { echo "✗ ${f} 缺少 desktop 端口访问开关"; exit 1; }
    grep -q 'wizard_dash_port_access' "${X}/${f}" \
        || { echo "✗ ${f} 缺少 dashboard 端口访问开关"; exit 1; }
done
# 应用信息：发布者仍是 soul87，其余归 Hermes 官方
grep -qE '^developer[[:space:]]*=[[:space:]]*Hermes[[:space:]]*$' "${X}/manifest" \
    || { echo "✗ manifest 的 developer 应为 Hermes（官方）"; exit 1; }
grep -qE '^maintainer[[:space:]]*=[[:space:]]*soul87' "${X}/manifest" \
    || { echo "✗ manifest 的 maintainer 应为 soul87"; exit 1; }
# 统一网关默认指向 desktop：cmd/main 必须用 gateway_upstream_port 决定上游端口，
# 且 gateway 进程要 source 凭据（否则 desktop 登录必 401）
grep -q 'gateway_upstream_port' "${X}/cmd/main" \
    || { echo "✗ cmd/main 缺少 gateway_upstream_port（网关未指向 desktop）"; exit 1; }
grep -q 'HERMES_WEBAPP_DIST' "${X}/cmd/main" \
    || { echo "✗ cmd/main 未把 HERMES_WEBAPP_DIST 传给 gateway"; exit 1; }
grep -q 'AUTH_ENV_FILE' "${X}/cmd/main" \
    || { echo "✗ cmd/main 缺少凭据文件机制"; exit 1; }
grep -q 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD' "${X}/cmd/main" \
    || { echo "✗ cmd/main 未注入 basic auth"; exit 1; }
grep -q 'envfile.sh' "${X}/cmd/main" \
    || { echo "✗ cmd/main 未加载 envfile.sh"; exit 1; }
grep -q 'install-runtime.sh' "${X}/cmd/install_callback" \
    || { echo "✗ install_callback 未调用 install-runtime.sh"; exit 1; }

# ── 关键：补丁必须已删除（防止回退到旧实现）──────────────
for fn in ensure_pm_env_ignored lazy_prune_redundant pm_bootstrap_kick \
          migrate_pm_venv_extras ensure_lazy_site_abi; do
    if grep -q "^${fn}() {" "${X}/cmd/main"; then
        echo "✗ cmd/main 仍含旧补丁 ${fn}"; exit 1
    fi
done
grep -q 'pm_venv_python()' "${X}/cmd/main" \
    || { echo "✗ cmd/main 缺少 pm_venv_python"; exit 1; }
echo "✓ 补丁已清除，改用 PM 真实 venv"

# ── web_dist 前缀别名（端口直连白屏修复）──────────────────
LINKS="$(tar -tvzf "${X}/app.tgz" | grep 'runtime/web_dist/app/hermes' || true)"
echo "$LINKS" | grep -q '^l' \
    || { echo "✗ web_dist 缺少 app/hermes 软链"; exit 1; }
echo "✓ web_dist 前缀别名存在"

# ── 档位专属断言 ──────────────────────────────────────────
if [ "${PRESET}" = "A" ]; then
    # 在线版不预置运行时；但含两个预构建前端：
    #   web_dist（dashboard，~10MB）+ webapp_dist（desktop，~37MB）
    # 故上限放到 110MB。超过说明又把 python/wheelhouse 打包进来了。
    if [ "${SIZE}" -gt 115343360 ]; then
        echo "✗ 在线版体积 $(du -h "${FPK}" | cut -f1) 超过 110MB —— 疑似又把运行时打包进去了"
        exit 1
    fi
    # 反向断言：A 版绝不能预置这些（预置了就说明 preset 判断失效）
    for f in ./runtime/python.tar.gz ./runtime/requirements.lock; do
        if echo "$A" | grep -qx "$f"; then
            echo "✗ 在线版不应含 ${f}（preset 判断可能失效）"; exit 1
        fi
    done
    if echo "$A" | grep -q '^\./runtime/wheelhouse/'; then
        echo "✗ 在线版不应含 wheelhouse（preset 判断可能失效）"; exit 1
    fi
    echo "✓ 档位 A：未预置运行时，体积 $(du -h "${FPK}" | cut -f1)（上限 110MB）"
else
    # ── B 版：预置 Python + wheelhouse ──
    if [ "${SIZE}" -gt 272629760 ]; then
        echo "✗ 档位B 体积 $(du -h "${FPK}" | cut -f1) 超过 260MB —— wheelhouse/Python 预置异常膨胀"
        exit 1
    fi
    for need in ./runtime/python.tar.gz ./runtime/requirements.lock; do
        echo "$A" | grep -qx "$need" || { echo "✗ 档位B 缺少 ${need}"; exit 1; }
    done
    echo "$A" | grep -q '^\./runtime/wheelhouse/' \
        || { echo "✗ 档位B 缺少 runtime/wheelhouse/"; exit 1; }

    # 真正解出 wheelhouse 看内容 —— 这是 Pillow 冲突修复的回归守卫。
    tar -xzf "${X}/app.tgz" -C "${X}" ./runtime/wheelhouse ./runtime/requirements.lock 2>/dev/null \
        || { echo "✗ 解包 wheelhouse 失败"; exit 1; }
    WH="${X}/runtime/wheelhouse"
    NW=$(ls "${WH}" | wc -l)
    [ "${NW}" -gt 0 ] || { echo "✗ wheelhouse 为空"; exit 1; }

    # Pillow 必须是 13.0.0：browser-harness 0.1.13 元数据精确 pin 12.3.0，
    # 能共存全靠 uv override。若 pip 又按传递依赖解析 → 冲突或退回 12.x。
    if ls "${WH}" | grep -qiE '^pillow-12\.'; then
        echo "✗ wheelhouse 含 Pillow 12.x —— override 失效（应只有 13.0.0）"
        ls "${WH}" | grep -i '^pillow-' | sed 's/^/    /'
        exit 1
    fi
    ls "${WH}" | grep -qiE '^pillow-13\.0\.0-' \
        || { echo "✗ wheelhouse 缺 Pillow 13.0.0"; ls "${WH}" | grep -i '^pillow-' | sed 's/^/    /'; exit 1; }
    echo "✓ Pillow 13.0.0 已入 wheelhouse（override 生效，未退回 12.x）"

    # requirements.lock 里也必须是 13.0.0
    grep -qiE '^pillow==13\.0\.0' "${X}/runtime/requirements.lock" \
        || { echo "✗ requirements.lock 未钉 Pillow==13.0.0"; grep -i '^pillow' "${X}/runtime/requirements.lock" | sed 's/^/    /'; exit 1; }

    # 抽样：关键 wheel 不得缺失（漏了会在装机期才炸）
    for pat in 'browser_harness' 'cbor2' 'websockets'; do
        ls "${WH}" | grep -qi "^${pat}-" || { echo "✗ wheelhouse 缺 ${pat}"; exit 1; }
    done
    echo "✓ 档位B：wheelhouse ${NW} 个 wheel，$(du -sh "${WH}" | cut -f1)，体积 $(du -h "${FPK}" | cut -f1)（上限 200MB）"
fi

echo "✓ 档位 ${PRESET} 校验通过"

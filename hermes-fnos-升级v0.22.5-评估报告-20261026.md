# Hermes fnOS 包 · 升级到 v0.22.5 评估报告

**日期**：2026-10-26
**当前**：`v0.22.2` / fpk `0.22.2-9`
**目标**：上游 `v0.22.5`（2026-10-23 发布，正式版）

---

## 一、结论摘要

| 项 | 结论 |
|---|---|
| 是否可升级 | ✅ **可以**，但有一处**结构性变化**需注意 |
| Python 要求 | 不变（`>=3.11,<3.15`），仍用 CPython 3.14.7 |
| 核心依赖 | 45 → 46 条，**全部仍带 `>=3.14` 标记**，**无新增包**（只有版本升级） |
| **重大变化** | **所有消息平台适配器从 `gateway/platforms/` 移到了 `plugins/platforms/`** |
| 对 QQ 的影响 | 插件化后**依赖仍是 aiohttp/httpx**（`messaging` extra 已覆盖）；`HERMES_BUNDLED_PLUGINS` 已指向 `plugins/`，**无需改打包逻辑** |
| PM 守卫 | `pm/environments.py` 仍在 → 现有守卫继续有效 |

---

## 一·补、⚠ 已发现的阻塞项：上游依赖冲突（必须处理）

### 现象

用 v0.22.5 的依赖清单解析时直接失败：

```
error: No solution found when resolving dependencies
  cause: Because browser-harness>=0.1.13 depends on pillow==12.3.0
         and you require browser-harness==0.1.13, we can conclude that
         your requirements and pillow==13.0.0 are incompatible.
```

### 根因

v0.22.5 的 `pyproject.toml` 里：

- 核心依赖：`Pillow==13.0.0`（第 180 行）
- 核心依赖：`browser-harness==0.1.13`（第 141 行）
- 而 `browser-harness 0.1.13` **内部 pin 了 `pillow==12.3.0`（精确 `==`）**

### 上游怎么解决的

`pyproject.toml` 第 629-640 行有 `[tool.uv] override-dependencies`：

```toml
# browser-harness 0.1.13 (core dependency, latest release) pins
# pillow==12.3.0 exactly, which holds Pillow below 13.0.0, the first
# release past the 13.0.0 advisory set. browser-harness only opens, converts,
# composes ... Remove this line when browser-harness allows Pillow 13.
"Pillow==13.0.0",
```

注释说明：browser-harness 只做 open/convert/compose，Pillow 13 兼容。

### 为什么我们踩到

我们的 `build.sh` 用 **`uv pip install -r deps.txt`**，**不读 `pyproject.toml` 的 `[tool.uv]`** → override 不生效 → 冲突暴露。

### 修复（已实施）

`build.sh` 生成 `uv-overrides.txt`（内容 `Pillow==13.0.0`），并传给 uv：

```bash
"${UV}" pip install ... --overrides "$(winpath "${OVERRIDES_TXT}")" -r deps.txt
```

**实测**：加 override 后 `uv pip compile` 成功解析（不再是 unsatisfiable）。

> 维护提示：上游改了这个 override 时（比如 browser-harness 放开 Pillow 13），同步更新 `build.sh` 里的列表。

---

## 二、版本差异详情

### 2.1 核心依赖（45 → 46）

| 变化 | 包 | 说明 |
|---|---|---|
| ⬆️ | `Pillow` 12.3.0 → **13.0.0** | 大版本跳跃，需验证图片处理 |
| ⬆️ | `PyJWT[crypto]` 2.13.0 → **2.15.1** | |
| ⬆️ | `certifi` 2026.5.20 → **2026.10.19** | |
| ⬆️ | `urllib3` `>=2.7.0` → **`>=2.8.0`** | 下限提高 |
| ➕ | `ruamel.yaml.clib==0.2.15` | **新增**（C 扩展，加速 ruamel.yaml）|

**全部仍带 `python_version >= '3.14'` 标记** —— 与 v0.22.2 一致，所以在 3.12 下依然会被全部过滤（这也是我们必须用 3.14 的原因，不变）。

### 2.2 `messaging` extra（我们打包用到的）

| 变化 | 包 |
|---|---|
| ⬆️ | `aiohttp` 3.14.3 → **3.14.5** |

其余（python-telegram-bot / discord.py / slack-bolt / qrcode / brotlicffi）不变。

### 2.3 其他 extras（我们不打包，仅供参考）

- `computer-use`: `mcp` 2.0.0 → 2.3.0
- `edge-tts`: 7.2.7 → 7.3.1
- `mistral`: `mistralai` 2.4.8 → 2.10.1
- `otlp`: opentelemetry 1.39.1 → 1.45.1
- `kittentts` / `piper` / `faster-whisper`: 平台条件微调（无实质变化）

---

## 三、⚠ 重大结构变化：消息平台改为插件

### 3.1 变化内容

| | v0.22.2 | v0.22.5 |
|---|---|---|
| QQ 适配器路径 | `gateway/platforms/qqbot/` | **`plugins/platforms/qqbot/`** |
| 其他平台 | `gateway/platforms/{telegram,discord,slack,...}` | **`plugins/platforms/{...}`** |
| 加载机制 | `gateway/run.py` 里的 `_BUILTIN_ADAPTERS` 硬编码 | `plugins/plugin_loader.py` 扫描 `plugin.yaml` |
| 新增目录 | — | `hermes_platform/`（平台宿主框架）|

`gateway/platforms/` 现在只剩 `base.py`、`api_server*`、`webhook*` 等基础设施，**没有任何具体平台适配器**。

### 3.2 QQ 插件结构（v0.22.5）

```
plugins/platforms/qqbot/
├── __init__.py
├── adapter.py          ← 适配器主体
├── chunked_upload.py
├── constants.py
├── crypto.py
├── gateway_env.py
├── keyboards.py
├── onboard.py
├── plugin.yaml         ← 插件声明（requires_env: QQ_APP_ID / QQ_CLIENT_SECRET）
├── register.py
├── send.py
└── utils.py
```

**依赖不变**：`adapter.py` 仍 import `aiohttp` 与 `httpx` → 我们的 `messaging` extra 已覆盖。

### 3.3 对我们打包的影响

| 检查项 | 结果 |
|---|---|
| `build.sh` 是否排除 `plugins/`？ | ❌ **没有排除**（只会排除 `apps/desktop`、测试文件、`contributors/emails`）→ ✅ 会随包分发 |
| `HERMES_BUNDLED_PLUGINS` 指向哪？ | `${SRC_DIR}/plugins` → ✅ 插件能被发现 |
| 是否需要额外装插件依赖？ | ❌ 不需要（qqbot 插件只用 aiohttp/httpx）|

**结论：无需改打包逻辑。** 但要**实测确认插件能被加载**（见 §五）。

### 3.4 潜在风险

| 风险 | 说明 | 验证方式 |
|---|---|---|
| 插件默认启用？ | 需确认 `plugin.yaml` 是否需显式 `enabled: true` | 装后看 `gateway.log` 是否 `qqbot connected` |
| 插件配置迁移 | v0.22.2 的 QQ 配置在 `.env`（`QQ_APP_ID` 等），v0.22.5 插件读 `requires_env` → **变量名相同** | 应无迁移问题 |
| `hermes_platform` 新模块 | 我们没排除它 | 随包分发，正常 |
| `ruamel.yaml.clib` | 新增 C 扩展，需 cp314 wheel | ⏳ 正在验证 |

---

## 四、其他不变项（确认无需改动）

| 项 | 状态 |
|---|---|
| `requires-python` | `>=3.11,<3.15`（不变）→ 仍用 CPython 3.14.7 |
| PBS tag | `20260929`（不变）|
| `pm/` 模块 | 仍在（`pm/environments.py`、`pm/install.py`、`pm/client.py` 均 200）→ PM 守卫继续有效 |
| `scripts/build/tui.mjs` | 存在（200）→ TUI 构建路径不变 |
| `web/vite.config.ts` | 存在（200）→ 前端构建不变 |
| `hermes` launcher | 存在（200）→ `~/.local/bin/hermes` 逻辑不变 |
| 我们的瘦身 | 与上游无关，继续适用（libpython/include/ensurepip/idlelib）|

---

## 五、升级前必须验证的项

### 5.1 依赖安装（进行中）

```
cp314 + v0.22.5 的 56 条依赖（core + web + messaging）
→ 是否全部有 wheel、能否全部安装、关键模块能否 import
```

**重点**：`ruamel.yaml.clib`（新增 C 扩展）、`Pillow 13.0.0`（大版本）、`aiohttp 3.14.5`。

### 5.2 装包后必须验证

```bash
# 1) 版本
hermes --version                      # 期望 v0.22.5

# 2) QQ 插件是否加载（关键！）
sudo grep -iE "qqbot|plugin.*platform" /vol1/@appdata/hermes/logs/gateway.log | tail -10
curl -s 127.0.0.1:9119/api/status | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('gateway_platforms'))"

# 3) 插件目录是否随包
ls /vol1/@appcenter/hermes/runtime/hermes/plugins/platforms/qqbot/

# 4) 核心功能
hermes doctor
curl -s 127.0.0.1:9119/api/health
```

---

## 六、升级步骤（建议）

### 6.1 改版本号

```bash
# upstream.version
v0.22.5

# fnos.version → 清空（跟随上游）
```

⚠ 我们给 `fnos.version` 加了**一致性保护**：若 `fnos.version=0.22.2-9` 而 `upstream.version=v0.22.5`，构建会**忽略 fnos.version 并告警**，最终用 `0.22.5`。清空更干净。

### 6.2 构建

```bash
git commit -m "升级上游到 v0.22.5"
bash .trigger-release.sh
```

### 6.3 安装方式

**重要**：从 `0.22.2-9` 升级到 `0.22.5` 是**上游版本变化**，版本号 `0.22.5 > 0.22.2-9` → **可以覆盖升级**（前提是 `uninstall_callback` 自我误杀的修复已在 `-9` 里，且那次修复验证通过）。

若覆盖升级仍失败，用「卸载（保留数据）+ 全新安装」。

---

## 七、风险评级

| 风险 | 等级 | 说明 |
|---|---|---|
| 依赖安装失败 | 🟢 低 | 只有版本升级 + 1 个新 C 扩展，正在验证 |
| **QQ 插件不加载** | 🟡 **中** | 插件化是新机制，需实测确认默认启用 |
| 配置迁移 | 🟢 低 | 环境变量名不变 |
| 其他平台（Telegram 等）| 🟢 低 | 同样插件化，依赖已覆盖 |
| 瘦身方案失效 | 🟢 低 | 与上游无关 |

---

## 八、待确认事项

1. ⏳ **依赖安装验证**（进行中）
2. ⏳ **QQ 插件默认启用状态**（需看 `plugin_loader.py` 逻辑或实测）
3. 是否保留 `0.22.2-9` 作为回退版本

---

## 附录：当前仓库状态

| 项 | 值 |
|---|---|
| HEAD | `890384b`（manifest 身份修正）|
| `upstream.version` | `v0.22.2` |
| `fnos.version` | `0.22.2-9` |
| 最近 Release | `v0.22.2-9` |
| 包体积（-8/-9）| 待确认（瘦身后应 ~185MB）|

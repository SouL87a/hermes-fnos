# 归档：旧打包方案（预置依赖 + 补丁）

本目录保存 `v0.22.5-6` 的完整打包代码，**仅作参考，不参与构建**。

---

## 为什么归档

`v0.22.5-6` 采用「预置 Python 运行时 + 预置依赖 + 452 行补丁」的方案：

- 包体积 197 MB
- 为解决「扁平依赖不被 PM 识别」打了约 450 行补丁
- 每次上游 PM 逻辑变动都要重新适配（v0.22.2 → v0.22.5 改过 3 次）

新方案改为**完全跟随上游 PM**：不预置 Python/依赖/源码，由 PM 在安装时自己建环境。
代价是首次安装需要联网下载。

---

## 这份代码里的补丁清单

`packaging/fnOS/cmd/main` 中：

| 函数 | 作用 |
|---|---|
| `ensure_pm_env_ignored` | 归档 PM 环境，避免它顶掉包内扁平依赖 |
| `pm_env_is_complete` | 判断 PM 环境 extras 是否含 messaging+web |
| `migrate_pm_venv_extras` | 归档前把插件依赖迁到 LAZY_SITE |
| `pm_env_site_packages` / `pm_env_state_dir` | 从 facts.json 解析 PM 环境路径 |
| `lazy_prune_redundant` + `lazy_prune_body` | 清理 LAZY_SITE 里 PM 已覆盖的冗余包 |
| `pm_bootstrap_kick` / `_needed` / `_extras` | 启动时后台补建 PM 环境 |
| `ensure_lazy_site_abi` | LAZY_SITE 的 Python ABI 守卫 |

这些补丁解决了以下真实问题，保留代码是因为新方案如果遇到同类问题可以参考：

1. **PM 接管后扁平依赖失效** → `ensure_pm_env_ignored`
2. **首次安装无 facts.json，懒安装被拒** → `pm_bootstrap_*`
3. **LAZY_SITE 被 activate 过滤掉** → `lazy_prune_*` 的门控
4. **`.disabled-*` 目录无限叠加** → glob 跳过
5. **`find` 深度写错导致功能静默失效** → 从 facts.json 读取而非猜测

---

## 关键教训（新方案要避免的坑）

1. **`find` 的 maxdepth 必须与实际路径深度核对**
   实际深度：`installs/<key>/environments/<gen>/venv/lib/python3.14/site-packages` = 7

2. **`running_from_selected_environment()` 只认 facts.json 或 manifest.json**
   光有 venv 不够，实机对照实验已证明

3. **`python -m venv` 在瘦身后不可用**（ensurepip 被删）
   必须用 `uv venv`

4. **PM 用的 Python 版本来自 `pm/lock.json`**，不是我们自己写死的
   必须以它为准，否则第一次 sync 就被换掉

5. **并发修改 PM 环境要加锁**
   bootstrap 与 `ensure_pm_env_ignored` 曾经互相拆台

---

## 如何取用

```bash
# 查看某个函数的原始实现
grep -A 30 "ensure_pm_env_ignored()" archive/v0.22.5-6/packaging/fnOS/cmd/main
```

对应的 release：https://github.com/SouL87a/hermes-fnos/releases/tag/v0.22.5-6

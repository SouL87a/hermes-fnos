# fnOS Hermes 打包 — 实机三项确认报告

- 采集时间：2026-10-03 17:16 CST
- 采集主机：NAS-SouL87（fnOS / TrimNAS，Debian 12，kernel 6.18.18.c1126-trim）
- 采集身份：`uid=872(hermes) gid=876(hermes)`（应用服务账号，无 sudo）
- 命令逐条实跑，输出见下；未跑到的项已明确标注「未验证」

---

## ① 商店 Python 应用的真名与路径

**结论：有应用，真名就是 `python312`（无后缀、无下划线）。系统还有 `/usr/bin/python3` = 3.11.2。**

| 项 | 实测值 |
|---|---|
| 应用目录 | `/vol1/@appcenter/python312`（属主 `python312:python312`，0775） |
| 控制脚本 | `/var/apps/python312/`（存在） |
| manifest `appname` | `"python312"` |
| manifest `version` | `3.12.4-11` |
| 解释器 | `/vol1/@appcenter/python312/bin/python3` → **Python 3.12.4** |
| 系统 python3 | `/usr/bin/python3` → `/usr/bin/python3.11`，**Python 3.11.2** |
| hermes 用户可用性 | 两者都能跑：`--version` 均正常返回 |
| venv/ensurepip | 两者都齐（`import venv, ensurepip` 成功） |

`ls /vol*/@appcenter/ | grep -i python` 只有一条：`python312`。
（另有 `bunjs`、`nodejs_v22`、`nodejs_v24`、`java-17-openjdk` 等应用，与 Python 无关。）

**要点：**
- `/usr/bin/python3` 是**系统包，不是应用** → 绝不能写进 `install_dep_apps`。
- `python312` 是应用 → 若要依赖它，`install_dep_apps` 写 `python312`。
- 但**当前 hermes 包并不需要它**：包自带 CPython 3.14.7
  （`/vol1/@appcenter/hermes/runtime/python/bin/python3` → `Python 3.14.7`），
  现有 manifest 的 `install_dep_apps = nodejs_v22` 里没有 python312。
- ⚠ 未验证：`python312` 的 manifest 是群晖移植风格
  （`os_min_ver="7.0-40000"`、`arch="apollolake avoton braswell ..."` 一大串）。
  它在飞牛上确实装上了，但**能否作为 `install_dep_apps` 依赖被飞牛安装器接受，我没有实机验证手段**。
  （`10238` 中止码是你的前提，我无法触发安装来复现。）

---

## ② uv 能否在 NAS 上装依赖

**结论：能。已用真实命令跑通「建 venv + 装包」，含无代理直连。**

| 项 | 实测值 |
|---|---|
| `command -v uv` | 空 |
| `${TRIM_PKGVAR}/bin/uv` | **不存在** |
| 包内 uv | **没有**（`/vol1/@appcenter/hermes` 下只有 `uv.lock`） |
| PM store 里的 uv | `/vol1/@appdata/hermes/tools/uv-0.12.3-linux-x64/uv`，`uv 0.12.3 (x86_64-unknown-linux-gnu)`，属主 hermes，权限 700 |
| astral.sh/uv/install.sh | 经代理 **200**；直连 **301**（重定向，curl 可跟随） |
| pypi.org/simple/ | 代理 200；直连 200 |
| pypi.tuna.tsinghua.edu.cn/simple/ | 代理 200；直连 200 |

**真机装包实测（在 scratch 目录，跑完已清理）：**

```
# 用商店 python312 作基
uv venv --python /vol1/@appcenter/python312/bin/python3 uvtest   → Using CPython 3.12.4, OK
uv pip install --python uvtest/bin/python3 six                   → Installed 1 package (+ six==1.17.0), real 1.08s

# 用系统 /usr/bin/python3 作基，且**去掉全部代理环境变量**、指定清华索引
uv venv --python /usr/bin/python3 uvtest2                        → Using Python 3.11.2, OK
uv pip install --python uvtest2/bin/python3 --default-index https://pypi.tuna.tsinghua.edu.cn/simple six
                                                                 → Installed 1 package (+ six==1.17.0)
```

**对 `install_callback` 的直接含义：**
- 它的 uv 候选只有 `${TRIM_PKGVAR}/bin/uv` 和 `command -v uv` —— **两者当前都不存在**，
  所以系统 Python 模式**必然走「联网下载 uv」分支**（`curl https://astral.sh/uv/install.sh`）。
  网络确实通，但这是安装期的硬联网依赖。
- 建议：构建时把 uv 二进制打进包（例如 `runtime/bin/uv`），并在候选列表里加上该路径，
  安装期就完全不需要 astral.sh。
- 当前环境代理来源：安装向导 `wizard_proxy` → 落盘 `$HERMES_HOME/.env`。
  已确认 `.env` 中存在 `HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY` 四个键（值未读取）。
  代理 = `http://192.168.68.68:20172/`，`NO_PROXY` 覆盖回环与内网段。
  **注意：主进程 environ 里只有 `wizard_proxy`，没有 `HTTP_PROXY`** ——
  代理是靠 `.env` 在应用内部加载的，不是从父进程继承。

---

## ③ hermes 用户对数据目录可写

**结论：可写。**

```
ls -ld /vol1/@appdata/hermes
  drwx------ 1 hermes hermes 2200 Oct  3 17:16 /vol1/@appdata/hermes

touch /vol1/@appdata/hermes/.wtest && echo 可写 && rm /vol1/@appdata/hermes/.wtest
  可写
```

附带（同属主、可写，但运行期不应写入）：
`/vol1/@appcenter/hermes` → `drwxrwxr-x hermes:hermes`。

---

## 补充事实（顺手采集，供定稿参考）

- 两个实例共存：`hermes`（dashboard 127.0.0.1:**9119**，`--skip-build`）与
  `trim.hermes`（dashboard 127.0.0.1:**19119**，自带 python3.11.real）。
- 运行中 hermes 进程（pid 3199607，Oct 02 起）环境：
  `HERMES_HOME=/vol1/@appdata/hermes`、`PYTHONPATH=<app>/runtime/hermes`、
  `HERMES_NODE=/var/apps/nodejs_v22/target/bin/node`（node **v22.18.0**，实跑确认）。
- 已随包存在：`fnos-depenv.py`(5955B)、`gateway-proxy.py`(39624B)。
- 磁盘：`/vol1` 1.9T 总，剩 **1.4T**（24% 使用）。

## 需要你决策的两点

1. **走哪种模式？**
   - 打包模式（自带 CPython 3.14.7，当前 `hermes` 包的做法）：**安装期零联网**，
     `install_dep_apps` 保持 `nodejs_v22`，① 的结论仅作信息，manifest 不用改。
   - 系统 Python 模式（`.use-system-python` → 安装时建 venv）：必须联网（uv + PyPI），
     且下面的候选列表问题必须先修。
2. **若走系统 Python 模式，`install_callback` 的 Python 候选列表要补**
   `/vol1/@appcenter/python312/bin/python3`。
   现在只有 `/usr/bin/python3`、`/usr/local/bin/python3`、`command -v python3`：
   本机 `/usr/bin/python3`=3.11.2 恰好落在 3.11–3.14 区间所以能过，
   但在系统 python 缺失或过旧的机器上会直接报「未找到系统 python3」——
   明明装了 `python312` 却用不上。
   同时若把 python312 声明为依赖，`install_dep_apps` 需写成 `nodejs_v22,python312`
   （逗号分隔，真名 `python312`）；其作为飞牛依赖的可用性见 ① 末尾的未验证项。

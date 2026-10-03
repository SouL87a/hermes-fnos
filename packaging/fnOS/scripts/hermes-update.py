#!/usr/bin/env python3
"""
Hermes Agent · 飞牛 fnOS 在线更新引擎。

为什么不用上游的 `hermes update`：
  它是**源码检出更新器**，要求 PROJECT_ROOT/.git 存在。本包刻意把 .git 移出工作树
  （放 runtime/hermes-git.git）—— 既是给在线更新用的 git 仓库，又让上游 `hermes update`
  在 Linux 上直接报 "Not a git repository" 而拒绝（堵住 git reset --hard 自伤）。
  这里自己实现同样的语义：用 GIT_DIR 定向到工作树外的 .git。

更新做什么（按用户选定：真·git 检出 + 同步重装依赖 + Python 不升级）：
  1. git fetch 目标 ref（分支或 tag）
  2. git reset --hard 到目标提交（代码树原地更新）
  3. 从新 pyproject.toml 抽依赖 → pip 重装进自带 CPython 的 site-packages
  4. 有 node/npm 就重建 web_dist（前端），没有就保留旧 dist 并警告
  5. 写状态文件，通知上层重启

回滚：依赖安装失败 → git reset 回旧提交 + 重装旧依赖。

CLI：
  hermes-update check    检查是否有新版本
  hermes-update apply    应用更新
  hermes-update status   查看当前/最近一次更新状态
  hermes-update version  打印当前版本

环境变量（都有默认值，fnOS 下由 cmd/main 注入）：
  HERMES_APP_ROOT   应用根（含 runtime/）
  HERMES_DATA_ROOT  可写数据目录（状态文件落这里）
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

# ── 路径 ─────────────────────────────────────────────────────
APP_ROOT = Path(os.environ.get("HERMES_APP_ROOT") or os.environ.get("TRIM_APPDEST") or "/var/apps/hermes")
DATA_ROOT = Path(os.environ.get("HERMES_DATA_ROOT") or os.environ.get("TRIM_PKGVAR") or (APP_ROOT / "var"))

RUNTIME = APP_ROOT / "runtime"
SRC = RUNTIME / "hermes"                 # 源码树（.git 可能在工作树内或 <APP>/runtime/hermes-git.git）
WEB_DIST = RUNTIME / "web_dist"          # 预构建前端

### 解释器：自带 CPython（默认）用包内解释器；系统 Python 模式（标记文件存在）用 NAS 上建的 venv。
### 与 cmd/main 的判定保持一致（都以 .use-system-python 标记为准）。
if (RUNTIME / ".use-system-python").exists():
    PY = DATA_ROOT / "venv" / "bin" / "python3"
else:
    PY = RUNTIME / "python" / "bin" / "python3"
STATE_FILE = DATA_ROOT / "update-state.json"
LOCK_FILE = DATA_ROOT / "update.lock"
CONFIG_FILE = DATA_ROOT / "update.json"

DEFAULT_REPO = "https://github.com/NousResearch/hermes-agent.git"


# ── 状态 ─────────────────────────────────────────────────────
def read_state() -> dict[str, Any]:
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def write_state(**fields: Any) -> None:
    state = read_state()
    state.update(fields)
    state["updated_at"] = int(time.time())
    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(STATE_FILE)


def read_config() -> dict[str, Any]:
    try:
        cfg = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        return cfg if isinstance(cfg, dict) else {}
    except (OSError, ValueError):
        return {}


def channel() -> str:
    return str(os.environ.get("HERMES_UPDATE_CHANNEL") or read_config().get("channel") or "main").strip()


def repo_url() -> str:
    return str(os.environ.get("HERMES_UPDATE_REPO") or read_config().get("repo") or DEFAULT_REPO).strip()


# ── 进程/工具 ────────────────────────────────────────────────
def run(cmd: list[str], cwd: Path | None = None, timeout: int = 600,
        env_extra: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    env = None
    if env_extra:
        env = {**os.environ, **env_extra}
    return subprocess.run(
        cmd, cwd=str(cwd) if cwd else None, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=timeout, check=False, text=True,
    )


def find_git() -> str | None:
    return shutil.which("git")


### .git 被移出工作树（放到 <APP>/runtime/hermes-git.git），见 build.sh。
### 原因：源码树里有 .git 会让上游 sealed_steward() 返回 None → `hermes update`
### 的准入判定放行 → 用户敲一次就会 git reset --hard（自伤，见第三轮审计 P0）。
### 把 .git 移出工作树后 sealed_steward 走 stamp 的 distribution 分支 → 被正确拒绝；
### 而我们的 hermes-update.py 用 GIT_DIR / GIT_WORK_TREE 定向，功能不受影响。
GIT_DIR_PATH = Path(os.environ.get("HERMES_UPDATE_GIT_DIR") or (APP_ROOT / "runtime" / "hermes-git.git"))
WORK_TREE = SRC


def _has_git() -> bool:
    """工作树内有 .git，或 .git 已移出（见 build.sh）—— 都算可用。"""
    return (SRC / ".git").exists() or GIT_DIR_PATH.is_dir()


def git_cmd(git: str, *args: str) -> tuple[list[str], dict[str, str]]:
    """构造指向「移出工作树的 .git」的 git 命令。

    返回 (argv, env_extra)。若外部 git dir 不存在（开发态/旧包），退回 `-C SRC`。
    """
    if GIT_DIR_PATH.is_dir():
        return ([git, *args],
                {"GIT_DIR": str(GIT_DIR_PATH), "GIT_WORK_TREE": str(WORK_TREE)})
    return ([git, "-C", str(WORK_TREE), *args], {})


def find_node_tool(name: str) -> str | None:
    """node/npm 可能在自带运行时、fnOS 应用中心的 nodejs、或 PATH 里。

    ⚠ 必须包含应用中心 nodejs 的路径：fnOS 上 node 由 nodejs_v22 应用提供，
    位于 /vol*/@appcenter/nodejs_v22/bin，既不在自带 runtime 也不在 PATH
    （第三轮审计实测：apply 因此跳过前端重建，留下"旧前端 × 新后端"错配）。
    """
    import glob as _glob
    cands = [
        RUNTIME / "python" / "node" / "bin" / name,
        APP_ROOT / "runtime" / "node" / "bin" / name,
        Path("/var/apps/nodejs_v22/target/bin") / name,
        Path("/var/apps/nodejs_v24/target/bin") / name,
    ]
    # 全卷 glob 兜底（应用可能装在任意存储空间）
    cands += [Path(p) for p in _glob.glob(f"/vol*/@appcenter/nodejs_v*/bin/{name}")]
    for cand in cands:
        if cand.exists() and os.access(cand, os.X_OK):
            return str(cand)
    # HERMES_NODE 指向的目录也试一下（cmd/main 会设置）
    hn = os.environ.get("HERMES_NODE")
    if hn and name != "node":
        sib = Path(hn).parent / name
        if sib.exists() and os.access(sib, os.X_OK):
            return str(sib)
    if hn and name == "node":
        return hn if os.access(hn, os.X_OK) else None
    return shutil.which(name)


# ── 版本 ─────────────────────────────────────────────────────
def local_version() -> dict[str, str]:
    """当前版本。

    注意：上游 package.json 是 "1.0.0"、pyproject 是 "0.0.0"，都是占位符 ——
    真实版本来自 git tag。所以优先 git describe。
    """
    out = {"version": "unknown", "commit": "", "ref": ""}
    git = find_git()
    # .git 可能已移出工作树（见 build.sh）—— 两种布局都认
    if git and ((SRC / ".git").exists() or GIT_DIR_PATH.is_dir()):
        _c, _e = git_cmd(git, "rev-parse", "--short", "HEAD"); head = run(_c, env_extra=_e, timeout=20)
        if head.returncode == 0:
            out["commit"] = head.stdout.strip()
        _c, _e = git_cmd(git, "describe", "--tags", "--always"); desc = run(_c, env_extra=_e, timeout=20)
        if desc.returncode == 0:
            out["ref"] = desc.stdout.strip()
            out["version"] = out["ref"]
    if out["version"] == "unknown":
        v = _pyproject_version(SRC)
        if v:
            out["version"] = v
    return out


def _pyproject_version(tree: Path) -> str | None:
    """从某棵树的 pyproject.toml 读版本（用于更新前预知新版本号）。"""
    py = tree / "pyproject.toml"
    try:
        text = py.read_text(encoding="utf-8")
    except OSError:
        return None
    m = re.search(r'^version\s*=\s*"([^"]+)"', text, re.MULTILINE)
    return m.group(1) if m else None


# ── 远端解析 ─────────────────────────────────────────────────
def resolve_target(git: str) -> tuple[str, str, str]:
    """返回 (kind, ref, label)。kind ∈ {branch, tag}。

    channel=main  → 分支 main
    channel=stable→ 最新稳定 tag（v2026.x.y 形式）
    channel=canary→ 最新 canary tag
    其它           → 当作分支名
    """
    ch = channel()
    if ch in ("main", "master") or "/" in ch:
        return "branch", ch, ch
    refs = _ls_remote_map(git)
    tags = [k[len("refs/tags/"):] for k in refs if k.startswith("refs/tags/") and not k.endswith("^{}")]
    if ch == "canary":
        cand = [t for t in tags if "canary" in t]
    elif ch == "stable":
        # 稳定 tag 形如 v2026.9.24（不含 canary）
        cand = [t for t in tags if "canary" not in t and re.match(r"^v?\d{4}\.\d", t)]
    else:
        cand = [t for t in tags if t == ch]
    if not cand:
        raise RuntimeError(f"channel={ch} 下没有可用 tag")
    # 按点分数字排序（YYYY.M.D[.N] 天然可排）
    def key(t: str):
        nums = re.findall(r"\d+", t)
        return [int(n) for n in nums]
    latest = sorted(cand, key=key)[-1]
    return "tag", latest, latest


def _ls_remote_map(git: str) -> dict[str, str]:
    """一次拿全量远端 refs → {refname: sha}。避免多次往返与 shell 转义问题。

    超时 20s（原 180s）：`check` 会被 dashboard 的 /system 首屏同步调用，
    而本机访问 github.com 实测 2~180s 不等 —— 180s 的超时会让页面转圈长达
    3 分钟（第三轮审计实测）。check 的定位是"快速看有没有新版本"，超时就
    如实报错，由调用方（代理）转成 update_available=null，不能拖住页面。
    GIT_TERMINAL_PROMPT=0：禁止 git 在凭据缺失时等交互输入（会挂到超时）。
    """
    _c, _e = git_cmd(git, "ls-remote", "origin")
    _e = {**_e, "GIT_TERMINAL_PROMPT": "0"}
    ls = run(_c, timeout=20, env_extra=_e)
    if ls.returncode != 0:
        raise RuntimeError(f"git ls-remote 失败：{ls.stdout.strip()[:200]}")
    out: dict[str, str] = {}
    for line in ls.stdout.splitlines():
        parts = line.split("\t") if "\t" in line else line.split()
        if len(parts) >= 2:
            out[parts[1].strip()] = parts[0].strip()
    return out


def remote_commit(git: str, kind: str, ref: str) -> str:
    """远端 ref 指向的 **commit** sha。

    annotated tag 的 ls-remote 给的是 tag 对象 sha，不等于它指向的 commit ——
    优先取 ``refs/tags/<t>^{}``（解引用行），否则会把「同一个 tag」误判成有更新。
    """
    refs = _ls_remote_map(git)
    if kind == "tag":
        deref = refs.get(f"refs/tags/{ref}^{{}}")
        if deref:
            return deref
    spec = f"refs/heads/{ref}" if kind == "branch" else f"refs/tags/{ref}"
    sha = refs.get(spec)
    if not sha:
        raise RuntimeError(f"无法解析远端 {spec}")
    return sha


# ── 依赖 ─────────────────────────────────────────────────────
def extract_deps(tree: Path) -> list[str]:
    """从源码树 pyproject.toml 抽 core + [web] 依赖，过滤自引用。"""
    import tomllib
    p = tomllib.loads((tree / "pyproject.toml").read_text(encoding="utf-8"))
    proj = p.get("project", {})
    deps = list(proj.get("dependencies", []))
    deps += list(proj.get("optional-dependencies", {}).get("web", []))
    return [d for d in deps if not d.strip().lower().startswith("hermes-agent")]


def _runnable_python() -> str | None:
    """能实际执行的 python。优先自带运行时，退回当前解释器。"""
    cands = [PY, Path(sys.executable) if sys.executable else None,
             Path(shutil.which("python3") or "") if shutil.which("python3") else None]
    for c in cands:
        if c and Path(c).exists() and os.access(c, os.X_OK):
            return str(c)
    return None


def install_deps(deps: list[str]) -> tuple[bool, str]:
    """用自带 CPython 的 pip/uv 装依赖。返回 (ok, 输出尾部)。

    超时 3600s：cp314 下个别原生轮子可能退化源码编译，慢但不应被误杀。
    日志写 DATA_ROOT/deps-install.log，失败时可查全量。
    """
    py = _runnable_python()
    if not py:
        return False, f"找不到可执行的 python（尝试过 {PY} 与 {sys.executable}）"
    deps_file = DATA_ROOT / ".deps.txt"
    deps_file.write_text("\n".join(deps), encoding="utf-8")
    log_file = DATA_ROOT / "deps-install.log"
    # 国内镜像（可覆盖）；飞牛在国内，默认走清华更快更稳
    index = os.environ.get("HERMES_PIP_INDEX") or read_config().get("pip_index") or ""
    extra = ["-i", index] if index else []

    # 优先 uv（快得多）；没有就 pip
    uv = shutil.which("uv") or str(RUNTIME / "python" / "bin" / "uv")
    if Path(uv).exists() and os.access(uv, os.X_OK):
        cmd = [uv, "pip", "install", "--python", py, *extra, "-r", str(deps_file)]
    else:
        cmd = [py, "-m", "pip", "install", "--disable-pip-version-check",
               "--no-input", *extra, "-r", str(deps_file)]

    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    try:
        with log_file.open("w", encoding="utf-8") as fh:
            fh.write("$ " + " ".join(cmd) + "\n\n")
            fh.flush()
            proc = subprocess.run(
                cmd, stdout=fh, stderr=subprocess.STDOUT,
                timeout=3600, check=False, text=True,
            )
        tail = "\n".join(log_file.read_text(encoding="utf-8", errors="replace").splitlines()[-40:])
        return proc.returncode == 0, tail
    except subprocess.TimeoutExpired:
        return False, "依赖安装超时（3600s），详见 deps-install.log"
    except OSError as exc:
        # 选中的解释器/uv 无法启动（架构不符、缺库、权限）—— 明确报错而非崩溃
        return False, f"无法启动包管理器（{cmd[0]}）：{exc}"
    finally:
        deps_file.unlink(missing_ok=True)


# ── 前端 ─────────────────────────────────────────────────────
def rebuild_web() -> tuple[bool, str]:
    """有 node/npm 就重建 web_dist。没有则保留旧 dist（可能过期但不影响启动）。

    ⚠ 必须用**包内自带的 web-build.mjs**，不能走上游 `npm run build`：
    上游 scripts/build/web.mjs 不传 Vite base，产物 base 会回到 "/"，
    而本包经 /app/hermes 前缀反代访问 —— JS 里懒加载 chunk 会请求
    /assets/...（无前缀）→ 404 → 每个 lazy 路由黑屏（入口 HTML 由服务端
    兜底改写，所以「外壳能渲染、内容区空」）。
    web-build.mjs 里传了 base='/app/hermes/'，与打包时保持一致。
    """
    npm = find_node_tool("npm")
    node = find_node_tool("node")
    if not (npm and node) or not (SRC / "web" / "package.json").exists():
        return False, "未找到 node/npm，跳过前端重建（沿用现有 web_dist）"

    builder = APP_ROOT / "runtime" / "web-build.mjs"
    if not builder.exists():
        # 老包没有该文件：宁可不重建，也不能产出无前缀 dist（会导致黑屏）
        return False, (f"缺少前端构建脚本 {builder}，跳过重建（避免产出无前缀 dist 导致黑屏）。"
                       "请改用新版 fpk。")

    env = dict(os.environ)
    env["PATH"] = f"{Path(node).parent}{os.pathsep}{env.get('PATH', '')}"
    env["HERMES_WEB_BASE"] = os.environ.get("HERMES_WEB_BASE", "/app/hermes/")
    try:
        # --ignore-scripts：避开会联网挂死的 postinstall（与 build.sh 同因）
        proc = run([npm, "install", "--no-audit", "--no-fund", "--ignore-scripts",
                    "--workspace", "web"], cwd=SRC, timeout=1800)
        if proc.returncode != 0:
            return False, "npm install 失败：" + "\n".join(proc.stdout.splitlines()[-20:])

        # web-build.mjs 以 cwd 为源码树根，复制过去执行（与 build.sh 同款用法）
        staged = SRC / ".hermes-web-build.mjs"
        shutil.copyfile(builder, staged)
        try:
            proc = run([node, str(staged)], cwd=SRC, timeout=1800)
        finally:
            staged.unlink(missing_ok=True)
        if proc.returncode != 0:
            return False, "前端构建失败：" + "\n".join(proc.stdout.splitlines()[-20:])

        built = SRC / "hermes_cli" / "web_dist"
        if not built.exists():
            return False, "构建产物缺失"

        # 自检：产物必须带前缀，否则更新完会黑屏。宁可失败也不覆盖现有 dist。
        idx = built / "index.html"
        if idx.exists():
            html = idx.read_text(encoding="utf-8", errors="replace")
            if "/app/hermes/assets/" not in html:
                return False, ("产物未带 /app/hermes 前缀（base 注入失败），"
                               "已中止以免更新后黑屏。原 web_dist 未改动。")

        if WEB_DIST.exists():
            shutil.rmtree(WEB_DIST, ignore_errors=True)
        shutil.copytree(built, WEB_DIST)
        return True, "前端已重建（含 /app/hermes 前缀）"
    except subprocess.TimeoutExpired:
        return False, "前端构建超时"


# ── 检查 ─────────────────────────────────────────────────────
def check_update() -> dict[str, Any]:
    git = find_git()
    if not git:
        return {"ok": False, "error": "no_git", "message": "系统未安装 git，无法在线更新"}
    if not _has_git():
        return {"ok": False, "error": "no_git_tree", "message": f"找不到 git 仓库：{SRC}（或 {GIT_DIR_PATH}）"}

    write_state(status="checking")
    try:
        kind, ref, label = resolve_target(git)
        remote = remote_commit(git, kind, ref)
    except Exception as exc:  # noqa: BLE001
        write_state(status="error", message=str(exc))
        return {"ok": False, "error": "resolve_failed", "message": str(exc)}

    cur = local_version()
    local_commit = cur.get("commit", "")
    # 比较完整 commit：local_version 给的是短 hash，这里取全量
    _c, _e = git_cmd(git, "rev-parse", "HEAD"); head_full = run(_c, env_extra=_e, timeout=20)
    head_full = head_full.stdout.strip() if head_full.returncode == 0 else ""
    available = bool(remote) and remote != head_full

    result = {
        "ok": True,
        "channel": channel(),
        "kind": kind,
        "ref": label,
        "current_version": cur.get("version", "unknown"),
        "current_commit": head_full[:12],
        "remote_commit": remote[:12],
        "available": available,
    }
    write_state(status="idle", last_check=result)
    return result


# ── 应用 ─────────────────────────────────────────────────────
def apply_update(force: bool = False) -> dict[str, Any]:
    git = find_git()
    if not git:
        return {"ok": False, "message": "系统未安装 git，无法在线更新"}
    if not _has_git():
        return {"ok": False, "message": f"找不到 git 仓库：{SRC}（或 {GIT_DIR_PATH}）"}

    # 前置：node/npm 必须在 —— 否则 apply 会推进 Python 源码却重建不了前端，
    # 留下「旧前端 × 新后端」的错配（第三轮审计 P0 第2条：「不要做一半」）。
    # 现在更新一定会重建前端（不再允许跳过），所以缺 node 就直接拒绝。
    if not all([find_node_tool("node"), find_node_tool("npm")]):
        return {"ok": False,
                "message": ("未找到 node/npm，无法重建前端；为避免新旧错配已中止更新。"
                            "请在应用中心安装 Node.js（nodejs_v22）后重试。")}

    if LOCK_FILE.exists():
        # 陈旧锁（>30 分钟）自动清理
        try:
            if time.time() - LOCK_FILE.stat().st_mtime > 1800:
                LOCK_FILE.unlink(missing_ok=True)
            else:
                return {"ok": False, "message": "已有更新在进行中"}
        except OSError:
            pass
    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    LOCK_FILE.write_text(str(os.getpid()), encoding="utf-8")

    steps: list[dict[str, Any]] = []

    def step(name: str, ok: bool, detail: str = "") -> None:
        steps.append({"name": name, "ok": ok, "detail": detail})
        write_state(status="updating", steps=steps)

    try:
        # 1. 解析目标
        kind, ref, label = resolve_target(git)
        remote = remote_commit(git, kind, ref)
        _c, _e = git_cmd(git, "rev-parse", "HEAD"); head_full = run(_c, env_extra=_e, timeout=20)
        head_full = head_full.stdout.strip() if head_full.returncode == 0 else ""

        # 「已是最新」必须同时满足：commit 匹配 **且** 依赖已为该 commit 同步过。
        # 否则一次被中断的更新（git 已切、依赖没装完）会被误判为完成而跳过装依赖。
        deps_commit = read_state().get("deps_commit", "")
        code_up_to_date = (remote == head_full)
        deps_up_to_date = (deps_commit == head_full)
        if not force and code_up_to_date and deps_up_to_date:
            step("解析目标", True, f"已是最新（{label}）")
            write_state(status="idle", message="已是最新")
            return {"ok": True, "up_to_date": True, "message": "已是最新版本", "steps": steps}
        step("解析目标", True, f"{label} @ {remote[:12]}")

        # 代码已就位但依赖没同步（上次被中断）→ 跳过 git，只补依赖
        skip_git = code_up_to_date and not deps_up_to_date
        if skip_git:
            step("git fetch", True, "跳过（代码已是最新，补装依赖）")
            step("git reset", True, "跳过")

        old_commit = head_full
        before = local_version()

        if not skip_git:
            # 2. 拉取。按 ref 名（不是裸 sha）—— 按 sha 取需要服务端允许，未必可用。
            fetch_spec = f"refs/tags/{ref}" if kind == "tag" else ref
            _c, _e = git_cmd(git, "fetch", "--depth", "1", "origin", fetch_spec); proc = run(_c, env_extra=_e, timeout=900)
            if proc.returncode != 0:
                # 回退：不带 --depth（老 git 或服务端限制）
                _c, _e = git_cmd(git, "fetch", "origin", fetch_spec); proc = run(_c, env_extra=_e, timeout=900)
            if proc.returncode != 0:
                step("git fetch", False, proc.stdout[-300:])
                write_state(status="error", message="git fetch 失败")
                return {"ok": False, "message": "git fetch 失败", "steps": steps}
            step("git fetch", True)

            # 3. 切代码。FETCH_HEAD 指向刚取到的 ref。
            #    reset --hard 不动 gitignore 的 web_dist / node_modules，前端产物得以保留。
            _c, _e = git_cmd(git, "reset", "--hard", "FETCH_HEAD"); proc = run(_c, env_extra=_e, timeout=300)
            if proc.returncode != 0:
                step("git reset", False, proc.stdout[-300:])
                write_state(status="error", message="git reset 失败")
                return {"ok": False, "message": "git reset 失败", "steps": steps}
            step("git reset", True, remote[:12])

        # 4. 重装依赖
        try:
            deps = extract_deps(SRC)
        except Exception as exc:  # noqa: BLE001
            step("读取依赖", False, str(exc))
            _rollback(git, old_commit, step)
            return {"ok": False, "message": f"新版本 pyproject 解析失败：{exc}", "steps": steps}
        ok, detail = install_deps(deps)
        step("重装依赖", ok, detail)
        if not ok:
            if skip_git:
                # 代码没动，不必回滚代码；只标记依赖未就绪，便于下次重试
                write_state(status="error", message="依赖安装失败（代码未改，可重试 apply）", steps=steps)
                return {"ok": False, "message": "依赖安装失败，可重试", "steps": steps}
            _rollback(git, old_commit, step)
            write_state(status="error", message="依赖安装失败，已回滚")
            return {"ok": False, "message": "依赖安装失败，已回滚到原版本", "steps": steps}

        # 记录「依赖已为哪个 commit 同步过」—— 中断恢复的判据
        _c, _e = git_cmd(git, "rev-parse", "HEAD"); head_now = run(_c, env_extra=_e, timeout=20)
        head_now = head_now.stdout.strip() if head_now.returncode == 0 else remote

        # 5. 前端
        # 必须成功：前端不重建 = 旧前端 × 新后端错配（lazy chunk 路径变了会 404）。
        # 失败则回滚代码与依赖，绝不留半成品。
        web_ok, web_detail = rebuild_web()
        step("重建前端", web_ok, web_detail)
        if not web_ok:
            if skip_git:
                write_state(status="error", message=f"前端重建失败：{web_detail}", steps=steps)
                return {"ok": False, "message": f"前端重建失败：{web_detail}", "steps": steps}
            _rollback(git, old_commit, step)
            write_state(status="error", message=f"前端重建失败，已回滚：{web_detail}", steps=steps)
            return {"ok": False, "message": f"前端重建失败，已回滚到原版本：{web_detail}", "steps": steps}

        after = local_version()
        write_state(
            status="restart_pending",
            deps_commit=head_now,
            message="更新完成，等待重启",
            from_version=before.get("version"),
            to_version=after.get("version"),
            from_commit=(old_commit or "")[:12],
            to_commit=remote[:12],
            steps=steps,
        )
        return {
            "ok": True,
            "message": "更新完成，需重启应用生效",
            "from_version": before.get("version"),
            "to_version": after.get("version"),
            "restart_required": True,
            "steps": steps,
        }
    finally:
        LOCK_FILE.unlink(missing_ok=True)


def _rollback(git: str, old_commit: str, step) -> None:
    if not old_commit:
        return
    _c, _e = git_cmd(git, "reset", "--hard", old_commit); run(_c, env_extra=_e, timeout=300)
    step("回滚代码", True, old_commit[:12])
    try:
        deps = extract_deps(SRC)
        ok, _ = install_deps(deps)
        step("回滚依赖", ok)
    except Exception:  # noqa: BLE001
        step("回滚依赖", False, "回滚时读取旧依赖失败")


# ── CLI ──────────────────────────────────────────────────────
def main(argv: list[str]) -> int:
    cmd = (argv[1] if len(argv) > 1 else "status").strip()
    if cmd == "check":
        r = check_update()
        print(json.dumps(r, ensure_ascii=False, indent=2))
        return 0 if r.get("ok") else 1
    if cmd == "apply":
        force = "--force" in argv
        r = apply_update(force=force)
        print(json.dumps(r, ensure_ascii=False, indent=2))
        return 0 if r.get("ok") else 1
    if cmd == "status":
        st = read_state()
        cur = local_version()
        print(json.dumps({"current": cur, "state": st, "channel": channel()},
                         ensure_ascii=False, indent=2))
        return 0
    if cmd == "version":
        print(local_version().get("version", "unknown"))
        return 0
    print("用法：hermes-update {check|apply [--force]|status|version}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

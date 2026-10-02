#!/usr/bin/env python3
"""fnOS 打包版 Hermes：为本次安装登记「已提交的依赖环境」（幂等）。

为什么需要
----------
本应用自带可重定位 CPython（runtime/python），依赖预装进它的 site-packages，
刻意不使用 PM 的 uv 构建，也不建 venv（venv 的 pyvenv.cfg / bin 符号链接带
构建机绝对路径，换机器会失效）。

但 PM 自己的 store Python 存在于 $HERMES_HOME/tools/ 下，而
``hermes_cli/_launchers.py::runtime_command()`` 会**优先**用它来 spawn 子进程
（`resolve_store_python(root) or sys.executable`）。子进程启动时
``pm/environments.py::activate_dependencies()`` 发现 install state 里没有任何
已提交的依赖环境，于是走 ``_require_own_dependencies()``：非 venv 解释器 +
``sys.base_prefix`` 落在 store 内 → 直接拒绝：

    hermes: no dependency environment is committed for this install; run `hermes pm repair`

凡是通过 ``runtime_command()`` 拉起的子进程都会死在这里：
dashboard 的 doctor / 安全审计 / 备份 / 导入 / curator / prompt-size / dump、
「重启网关」、cron 的 .py 脚本、更新接管等。

本脚本做的事
------------
等价于 PM 本来会做的那一步：在 install state 里登记一个依赖环境，其
site-packages 与解释器都指向自带 CPython。于是
``committed_venv()`` 不再返回 ``None``，``_require_own_dependencies()``
永远不被触达，而 PM 自己的工具链（uv / chromium / agent-browser / tirith）
行为完全不变（不写 manifest.json，所以不进入 sealed payload 模式）。

两种运行时模式都适用：
  * 打包模式：解释器 = <app>/runtime/python/bin/python3
  * 系统 Python 模式：解释器 = $TRIM_PKGVAR/venv/bin/python3

只写 install state（$HERMES_HOME/installs/<key>/），不改应用包。
"""
from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path

ENV_NAME = "fnos-package"
STAMP_SENTINEL = "fnos-package:bundled-runtime"


def _relink(link: Path, target: Path) -> None:
    """Make *link* a symlink to *target*, replacing anything else present."""
    if link.is_symlink():
        if Path(os.readlink(link)) == target:
            return
        link.unlink()
    elif link.exists():
        shutil.rmtree(link) if link.is_dir() else link.unlink()
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(target)


def main() -> int:
    src = Path(os.environ.get("HERMES_PKG_SRC") or Path(__file__).resolve().parent.parent).resolve()
    if not (src / "pm" / "environments.py").is_file():
        print(f"hermes-pkg: not a Hermes source tree: {src}", file=sys.stderr)
        return 1
    sys.path.insert(0, str(src))

    import sysconfig

    from pm.environments import install_state_dir, runtime_facts_path, site_packages, store_root

    # 必须用应用自己的解释器运行。用 PM 的 store Python 跑会把环境指向那个
    # 裸解释器，子进程虽然不再报 pm repair，却会在第一个 import 上崩掉。
    if Path(sys.base_prefix).resolve().is_relative_to(store_root(src).resolve()):
        print(
            f"hermes-pkg: refusing to run under the PM store interpreter "
            f"({sys.executable}); use the application's own interpreter",
            file=sys.stderr,
        )
        return 1

    # 解释器与它自己的 site-packages：两种运行时模式都由此推导，不写死版本号。
    interpreter = Path(sys.executable).resolve()
    real_site = Path(sysconfig.get_paths()["purelib"]).resolve()
    if not real_site.is_dir():
        print(f"hermes-pkg: site-packages not found: {real_site}", file=sys.stderr)
        return 1
    version = f"{sys.version_info.major}.{sys.version_info.minor}"

    env = install_state_dir(src) / "environments" / ENV_NAME / "venv"
    lib = env / "lib"
    # 解释器版本升级后（3.14 → 3.15）旧目录必须让位，否则 site_packages() 会挑错。
    if lib.is_dir():
        for stale in lib.glob("python*"):
            if stale.name != f"python{version}":
                shutil.rmtree(stale, ignore_errors=True)
    _relink(lib / f"python{version}" / "site-packages", real_site)
    _relink(env / "bin" / "python", interpreter)
    (env / "pyvenv.cfg").write_text(
        f"home = {interpreter.parent}\n"
        f"version = {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}\n",
        encoding="utf-8",
    )

    # stamp：PM 用 packages.venv.stamp 判断「依赖是否与 uv.lock 一致」。
    # 按同一算式如实计算；算不出时写一个非空哨兵 —— venv_is_current() 对空
    # 字符串会抛 ValueError，而对不匹配的字符串只是返回 False。
    try:
        from pm.packages import Venv

        stamp = Venv(src).expected_stamp([])
    except Exception as exc:  # noqa: BLE001 - 绝不因为算 stamp 让安装/启动失败
        print(f"hermes-pkg: stamp unavailable ({exc}); recording sentinel", file=sys.stderr)
        stamp = STAMP_SENTINEL

    facts_path = runtime_facts_path(src)
    try:
        facts = json.loads(facts_path.read_text(encoding="utf-8-sig"))
        if not isinstance(facts, dict):
            facts = {}
    except (OSError, ValueError):
        facts = {}
    facts.setdefault("schema", 1)
    facts.setdefault("packages", {})["venv"] = {
        "environment": str(env),
        "stamp": stamp,
        "extras": [],
    }
    facts_path.parent.mkdir(parents=True, exist_ok=True)
    facts_path.write_text(json.dumps(facts, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"hermes-pkg: committed dependency environment -> {env}")
    print(f"hermes-pkg:   interpreter  -> {interpreter}")
    print(f"hermes-pkg:   site-packages -> {site_packages(env)}")
    print(f"hermes-pkg:   facts        -> {facts_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

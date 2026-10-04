#!/usr/bin/env python3
"""
飞牛 fnOS 统一网关适配层：Unix Socket → 本机回环 TCP。

背景
====
Hermes dashboard（FastAPI + uvicorn）默认只应绑回环 —— 一旦绑非回环地址，
从 2026-06 的 hermes-0day 加固起会**强制要求 auth provider**（--insecure 已被
忽略）。因此本应用让 uvicorn 只监听 127.0.0.1:PORT，由本代理把飞牛统一网关的
Unix Socket 请求转过去。

前缀
====
飞牛统一网关把 /app/hermes/** 转到 ${APP_DIR}/hermes.sock，且**不剥前缀**。
Hermes 前端是 React Router SPA，其 API/WS 基址取自 index.html 里注入的
window.__HERMES_BASE_PATH__，而该值由服务端依据请求头 X-Forwarded-Prefix 生成
（见 hermes_cli/dashboard_auth/prefix.py 与 web_server_dashboard.mount_spa）。
所以本代理**不做任何 HTML 改写**，只需：
  1. 剥掉 /app/hermes 前缀后转发到上游；
  2. 给上游带 X-Forwarded-Prefix: /app/hermes。
服务端会据此改写 index.html 的资产 URL 并注入正确的 base path。

安全
====
socket 权限 0666：网关进程与应用用户可能不同 uid。
鉴权不依赖 socket 权限 —— 见下方 HERMES_GATEWAY_REQUIRE_TRIM。
注意：dashboard 绑回环时**不做 auth 门**，因此能连到本 socket 的本机进程即等价
于拥有控制台权限（可执行命令）。若你的威胁模型包含"本机不受信进程"，请设
HERMES_GATEWAY_REQUIRE_TRIM=1，强制只有带 X-Trim-* 身份头的网关请求才放行。

环境变量
========
  HERMES_GATEWAY_SOCKET       必填，socket 绝对路径
  HERMES_GATEWAY_PREFIX       默认 /app/hermes
  HERMES_UPSTREAM_HOST        默认 127.0.0.1
  HERMES_UPSTREAM_PORT        默认 9119
  HERMES_GATEWAY_REQUIRE_TRIM 默认 0；为 1 时无 X-Trim-* 的请求返回 403
  HERMES_GATEWAY_TCP_PORT     调试用：改走 TCP 监听（Windows 无法建 Unix Socket）
"""

import asyncio
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import time

SOCKET_PATH = os.environ.get("HERMES_GATEWAY_SOCKET", "")
PREFIX = os.environ.get("HERMES_GATEWAY_PREFIX", "/app/hermes").rstrip("/")
UP_HOST = os.environ.get("HERMES_UPSTREAM_HOST", "127.0.0.1")
UP_PORT = int(os.environ.get("HERMES_UPSTREAM_PORT", "9119") or "9119")
REQUIRE_TRIM = os.environ.get("HERMES_GATEWAY_REQUIRE_TRIM", "0") == "1"
# 诊断日志开关（真机排查用）：HERMES_GATEWAY_DEBUG=1
DEBUG = os.environ.get("HERMES_GATEWAY_DEBUG", "0") == "1"
TCP_PORT = int(os.environ.get("HERMES_GATEWAY_TCP_PORT", "0") or "0")

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


def log(msg: str) -> None:
    print(f"[gateway] {time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}", flush=True)


def has_trim(headers) -> bool:
    for k, _ in headers:
        if k.lower().startswith("x-trim-"):
            return True
    return False


def strip_prefix(path: str) -> str:
    if not PREFIX:
        return path or "/"
    if path == PREFIX:
        return "/"
    if path.startswith(PREFIX + "/"):
        return path[len(PREFIX):] or "/"
    # 网关外路径（理论不应出现）原样透传
    return path or "/"


def _split_target(target: str):
    """把 request-target 拆成 (path, query)（query 含前导 ?，无则空串）。"""
    if "?" in target:
        path, _, query = target.partition("?")
        return path, "?" + query
    return target, ""


# ── 在线更新控制端点 ─────────────────────────────────────────
# 路径：/__hermes/update/{check,apply,status,version}
# 权限：必须带 X-Trim-Isadmin（飞牛管理员），否则 403。
# 实现：调用同目录的 hermes-update.py（用同一个自带 python）。
UPDATE_SCRIPT = os.environ.get("HERMES_UPDATE_SCRIPT", "")

# 应用内容树根：本代理脚本部署在 <APP_ROOT>/gateway-proxy.py
# （注意 cmd/main 不在这里，见 find_cmd_main）
APP_ROOT = os.environ.get("HERMES_APP_ROOT") or os.path.dirname(os.path.abspath(__file__))

# ── 网关动作结果登记（修「重启网关」假失败）─────────────────────
# 背景：dashboard 的动作条（index chunk）在 POST /api/gateway/{restart,start,stop}
# 之后，会轮询 GET /api/actions/gateway-*/status，并用 `exit_code === 0` 判成功。
# 但上游的 exit_code 只从【上游进程内】的 _ACTION_PROCS/_ACTION_RESULTS 推导
# （hermes_cli/web_routers/actions.py）—— 而我们的动作是**代理自己**执行的，上游
# 毫不知情 → 返回 {"running":false,"exit_code":null} → 前端 `null !== 0` → 误报
# 「操作失败 (?)」，尽管服务端 100% 成功。
# 解法：代理记录自己执行过的动作结果，接管 status 端点返回真实的 exit_code。
_GATEWAY_ACTION_RESULTS: dict = {}   # name -> {"exit_code": int, "lines": [str], "at": float}
_GATEWAY_ACTION_TTL = float(os.environ.get("HERMES_GATEWAY_ACTION_TTL", "600") or "600")
_GATEWAY_ACTION_NAMES = ("gateway-restart", "gateway-start", "gateway-stop")


def _record_gateway_action(name: str, exit_code: int, lines) -> None:
    """登记一次网关动作的真实结果（供随后 dashboard 的 status 轮询读取）。"""
    if isinstance(lines, str):
        lines = [lines] if lines else []
    _GATEWAY_ACTION_RESULTS[name] = {
        "exit_code": int(exit_code),
        "lines": [str(x) for x in (lines or [])][-20:],
        "at": time.time(),
    }


def _gateway_action_status(name: str):
    """取近期登记的结果；过期或不存在返回 None（调用方回退转发上游）。"""
    rec = _GATEWAY_ACTION_RESULTS.get(name)
    if not rec:
        return None
    if (time.time() - rec.get("at", 0)) > _GATEWAY_ACTION_TTL:
        _GATEWAY_ACTION_RESULTS.pop(name, None)
        return None
    return rec


def _update_script_path() -> str:
    if UPDATE_SCRIPT and os.path.exists(UPDATE_SCRIPT):
        return UPDATE_SCRIPT
    # 默认：与代理同目录
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "hermes-update.py")


def find_cmd_main() -> str | None:
    """定位应用生命周期脚本 cmd/main。

    ⚠ 它**不在**应用内容树里：fnOS 把 fpk 顶层的 cmd/ 装到 <appdata>/cmd/，
    而应用内容树（app.tgz 解出的东西）在 /vol1/@appcenter/<app>/。
    实测真机路径是 /var/apps/hermes/cmd/main（/var/apps 是 fnOS 统一视图，
    跨卷有效）。这里按可能性依次探测，全部落空返回 None。
    """
    # 首选由 cmd/main 自己注入的真实路径（零猜测）
    cands = []
    env_path = os.environ.get("HERMES_CMD_MAIN", "").strip()
    if env_path:
        cands.append(env_path)
    env_dir = os.environ.get("HERMES_APP_CTL_DIR", "").strip()
    if env_dir:
        cands.append(os.path.join(env_dir, "main"))
    cands += [
        os.path.join(APP_ROOT, "cmd", "main"),   # 与代理同级（若布局不同）
        "/var/apps/hermes/cmd/main",             # fnOS 统一视图（真机实测）
        "/var/apps/hermes/target/cmd/main",
    ]
    # 全卷兜底：/vol*/@appcenter/hermes/cmd/main 与 @appdata
    import glob as _glob
    cands += _glob.glob("/vol*/@appcenter/hermes/cmd/main")
    cands += _glob.glob("/vol*/@appdata/hermes/cmd/main")
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return None


def peer_uid(writer) -> int | None:
    """Unix socket 对端进程的 uid（SO_PEERCRED）。取不到返回 None。

    用途：区分「飞牛网关注入的 X-Trim-*」（对端是 root）与「本机其它进程
    自己伪造的」（对端非 root）。socket 是 0666，任何本机进程都能连，
    所以不能只看头是否存在 —— 必须看来路。
    """
    try:
        tsock = writer.get_extra_info("socket")
        if tsock is None:
            return None
        fd = tsock.fileno()
        dup = os.dup(fd)
        s = None
        try:
            s = socket.socket(fileno=dup)
            dup = -1  # 所有权交给 s
            fmt = struct.calcsize("3i")
            raw = s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, fmt)
            _pid, uid, _gid = struct.unpack("3i", raw)
            return uid
        finally:
            if s is not None:
                s.close()
            elif dup >= 0:
                os.close(dup)
    except Exception:  # noqa: BLE001
        return None


def _is_admin(headers, from_root: bool = False) -> bool:
    """是否为飞牛管理员请求。

    from_root=True 表示对端是 root（飞牛网关），此时信任 X-Trim-Isadmin。
    否则视为不可信来源：本机普通进程可自加该头（socket 0666），
    一律不认。
    """
    if not from_root:
        return False
    for k, v in headers:
        if k.lower() == "x-trim-isadmin":
            return v.strip().lower() in ("1", "true", "yes")
    return False


# ── 更新检查：超时 + 缓存（含失败缓存）───────────────────────
# 为什么：dashboard 的 /system 首屏把 checkHermesUpdate 和 9 个本地接口绑在同一个
# Promise.allSettled 里，只有全部 settle 才关转圈。而 check 要跑 `git ls-remote`
# 打 github.com —— 大陆网络实测成功率约 30%，失败时固定卡满超时。
#
# 三条关键设计（少了任一条这个按钮就会拖垮系统页）：
#  ① 硬超时（见下 UPDATE_CHECK_TIMEOUT）：**只兜底、不用于掐短**。check 已改为
#     后台线程执行（_kick_update_check_background），不再在请求路径上，所以这个
#     超时可以放宽到覆盖 git 的长尾，让 hermes-update.py 内部的 60s 超时 + 重试
#     有机会生效（原先 3s 会先把内部 20s 砍掉，重试永远轮不到）。
#  ② **失败/超时结果也要缓存**（短 TTL）：否则「GitHub 不通」期间每次进
#     /system 都要重付一次超时 —— 这正是上一版最致命的遗漏；
#  ③ 成功结果用长 TTL（10 分钟），失败结果用短 TTL（90 秒）以便稍后自愈。
UPDATE_CHECK_TIMEOUT = float(os.environ.get("HERMES_UPDATE_CHECK_TIMEOUT", "150"))
UPDATE_CHECK_TTL = float(os.environ.get("HERMES_UPDATE_CHECK_TTL", "600"))
UPDATE_CHECK_FAIL_TTL = float(os.environ.get("HERMES_UPDATE_CHECK_FAIL_TTL", "90"))
_update_check_cache: dict = {"at": 0.0, "payload": None, "ttl": 0.0}
# 上一次【成功】的检查结果：本次失败（网络抖动）时回退展示它，避免 UI 从
# 「可更新到 xxx」瞬间变成「无数据」（真机报告 §2.3）。
_update_check_last_ok: dict = {"payload": None}


def _update_check_cached_or_none() -> dict | None:
    """命中未过期缓存则返回，否则 None（供调用方决定"阻塞查"还是"后台查"）。"""
    import time as _t
    if _update_check_cache["payload"] and \
            (_t.time() - _update_check_cache["at"]) < _update_check_cache["ttl"]:
        return _update_check_cache["payload"]
    return None


_check_inflight = {"running": False}


def _kick_update_check_background() -> None:
    """后台跑一次检查（不阻塞请求）。同一时刻只跑一个。"""
    import threading
    if _check_inflight["running"]:
        return
    def _work() -> None:
        _check_inflight["running"] = True
        try:
            _run_update_check_cached()
        except Exception as exc:  # noqa: BLE001
            log(f"background update check failed: {exc!r}")
        finally:
            _check_inflight["running"] = False
    threading.Thread(target=_work, daemon=True).start()


def _run_update_check_cached() -> dict:
    """同步执行一次检查并写缓存（供后台线程 / 诊断调用，不在请求路径上）。"""
    d: dict = {}
    ok = False
    try:
        # 硬超时：_run_update 内部 subprocess 有各自的 timeout，这里再兜一层，
        # 保证代理线程不会无限等（例如 git 卡在 DNS/凭据交互）。
        _code, body = _run_update("check", timeout=UPDATE_CHECK_TIMEOUT + 2)
        try:
            d = json.loads(body)
        except ValueError:
            d = {"ok": False, "message": (body or "")[:200]}
        ok = bool(d.get("ok"))
    except Exception as exc:  # noqa: BLE001
        d = {"ok": False, "message": f"检查超时或失败：{exc}"}

    payload = {
        "install_method": "fnos-fpk",
        "current_version": d.get("current_version") or "unknown",
        "behind": None,
        # 检查失败/超时 → None（前端按"未知"处理），而不是 false，
        # 避免把"没查到"说成"已是最新"。
        "update_available": (bool(d.get("available")) if ok else None),
        "can_apply": True,
        "update_command": "hermes-update apply",
        "message": d.get("message") or (
            f"可更新到 {d.get('ref')}" if d.get("available") else "已是最新版本"
        ),
    }
    import time as _t
    if ok:
        _update_check_last_ok["payload"] = payload
    else:
        # 本次失败（网络抖动）→ 若有上次成功结果，回退展示它并标注「上次结果」，
        # 避免 UI 从「可更新到 xxx」瞬间变成「无数据」（报告 §2.3）。
        last = _update_check_last_ok["payload"]
        if last:
            payload = {
                **last,
                "update_available": last.get("update_available"),
                "stale": True,
                "message": (last.get("message") or "") + "（上次检查结果，本次查询超时）",
            }
    # 成功与失败都缓存 —— 失败用短 TTL，避免"GitHub 不通"期间反复付超时。
    _update_check_cache["at"] = _t.time()
    _update_check_cache["payload"] = payload
    _update_check_cache["ttl"] = UPDATE_CHECK_TTL if ok else UPDATE_CHECK_FAIL_TTL
    return payload


# 自包含更新页（零依赖、不引用外部资源）。路径：<前缀>/__hermes/update/ui
UPDATE_UI_HTML = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hermes 更新</title>
<style>
:root{color-scheme:dark}
body{margin:0;font:15px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif;
  background:#0f1115;color:#e6e6e6;padding:24px;max-width:820px;margin:0 auto}
h1{font-size:20px;margin:0 0 4px}
.sub{color:#8b93a1;font-size:13px;margin-bottom:20px}
.row{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:18px}
button{font:inherit;padding:9px 16px;border-radius:8px;border:1px solid #2a2f3a;
  background:#1a1f2b;color:#e6e6e6;cursor:pointer}
button:hover:not(:disabled){background:#232a38}
button:disabled{opacity:.5;cursor:not-allowed}
button.primary{background:#2563eb;border-color:#2563eb;color:#fff}
button.primary:hover:not(:disabled){background:#1d4ed8}
pre{background:#141821;border:1px solid #232a38;border-radius:8px;padding:14px;
  overflow:auto;font-size:13px;white-space:pre-wrap;word-break:break-word;margin:0}
.badge{display:inline-block;padding:2px 8px;border-radius:6px;font-size:12px;margin-left:8px}
.ok{background:#14351f;color:#4ade80}.warn{background:#3a2f10;color:#fbbf24}
.err{background:#3a1717;color:#f87171}
.hint{color:#8b93a1;font-size:12px;margin-top:10px}
</style></head><body>
<h1>Hermes 在线更新</h1>
<div class="sub">从上游仓库拉取新版本（代码 + 依赖）。更新后需重启应用生效。</div>
<div class="row">
  <button id="check">检查更新</button>
  <button id="apply" class="primary">立即更新</button>
  <button id="status">当前状态</button>
</div>
<div id="out"><pre>点击「检查更新」开始。</pre></div>
<div class="hint">仅飞牛管理员可操作。更新过程中请勿关闭页面。</div>
<script>
const $=s=>document.querySelector(s);
const out=$("#out");
function show(txt,cls){out.innerHTML='<pre>'+String(txt).replace(/[<>&]/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;'}[c]))+'</pre>';
  if(cls){const b=document.createElement('span');b.className='badge '+cls;b.textContent=cls==='ok'?'完成':cls==='err'?'失败':'进行中';out.prepend(b);}}
async function call(action,method){
  const r=await fetch("/__hermes/update/"+action,{method:method||"GET",headers:{"Accept":"application/json"}});
  const t=await r.text(); let d; try{d=JSON.parse(t)}catch(e){d={raw:t}}
  return {status:r.status,data:d};
}
function fmt(d){
  if(d.raw!==undefined)return d.raw;
  let s="";
  if(d.message)s+=d.message+"\\n";
  if(d.available!==undefined)s+="可用更新："+(d.available?"是":"否")+"\\n";
  if(d.current_version)s+="当前版本："+d.current_version+" ("+(d.current_commit||"")+")\\n";
  if(d.remote_commit)s+="远端提交："+d.remote_commit+"\\n";
  if(d.from_version)s+="更新："+d.from_version+" → "+d.to_version+"\\n";
  if(d.steps&&d.steps.length){s+="\\n步骤：\\n";for(const x of d.steps)s+="  ["+(x.ok?"OK":"FAIL")+"] "+x.name+(x.detail?" — "+x.detail:"")+"\\n";}
  if(d.restart_required)s+="\\n⚠ 需重启应用生效\\n";
  return s||JSON.stringify(d,null,2);
}
function busy(b){for(const id of["check","apply","status"])$("#"+id).disabled=b;}
$("#check").onclick=async()=>{busy(1);show("检查中…");const{data}=await call("check");
  show(fmt(data),data.available?"warn":data.ok?"ok":"err");busy(0);};
$("#status").onclick=async()=>{busy(1);const{data}=await call("status");show(fmt(data),"ok");busy(0);};
$("#apply").onclick=async()=>{
  if(!confirm("确定更新到最新版本？更新过程中服务会短暂中断。"))return;
  busy(1);show("更新中…（安装依赖可能耗时数分钟，请勿关闭）");
  const{data}=await call("apply","POST");
  show(fmt(data),data.ok?"ok":"err");busy(0);
  if(data.ok&&data.restart_required)show(fmt(data)+"\\n\\n→ 请到应用中心重启 Hermes。","ok");
};
$("#status").click();
</script></body></html>"""



def _run_update(action: str, timeout: float = 3600) -> tuple[int, str]:
    script = _update_script_path()
    if not os.path.exists(script):
        return 500, json.dumps({"ok": False, "message": f"缺少更新脚本：{script}"}, ensure_ascii=False)
    py = sys.executable or "python3"
    try:
        proc = subprocess.run(
            [py, script, action],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=timeout, check=False, text=True,
        )
        body = proc.stdout.strip()
        # 脚本输出是 JSON；原样透传
        return (200 if proc.returncode == 0 else 500), body
    except subprocess.TimeoutExpired:
        return 504, json.dumps({"ok": False, "message": f"更新操作超时（{int(timeout)}s）"},
                               ensure_ascii=False)
    except OSError as exc:
        return 500, json.dumps({"ok": False, "message": f"无法执行更新脚本：{exc}"}, ensure_ascii=False)


async def handle_update_endpoint(method: str, up_path: str, headers, writer, from_root: bool = False) -> None:
    def respond(code: int, body: str, ctype: str = "application/json; charset=utf-8") -> None:
        raw = body.encode("utf-8")
        writer.write(
            f"HTTP/1.1 {code} {_reason(code)}\r\n"
            f"Content-Type: {ctype}\r\n"
            f"Content-Length: {len(raw)}\r\n"
            "Cache-Control: no-store\r\n"
            "Connection: close\r\n\r\n".encode("latin-1") + raw
        )

    if not _is_admin(headers, from_root):
        respond(403, json.dumps({"ok": False, "message": "仅飞牛管理员可执行更新"}, ensure_ascii=False))
        await writer.drain()
        writer.close()
        return

    action = up_path[len("/__hermes/update"):].strip("/") or "status"

    # 独立更新页面（零侵入：不改 dashboard 的 HTML）
    if action in ("ui", "ui.html"):
        respond(200, UPDATE_UI_HTML, "text/html; charset=utf-8")
        await writer.drain()
        writer.close()
        return

    mapping = {"check": "check", "apply": "apply", "status": "status", "version": "version"}
    if action not in mapping:
        respond(404, json.dumps({"ok": False, "message": f"未知动作：{action}"}, ensure_ascii=False))
        await writer.drain()
        writer.close()
        return
    # apply 有副作用 → 只允许 POST（避免被预取/爬虫触发）
    if action == "apply" and method != "POST":
        respond(405, json.dumps({"ok": False, "message": "apply 需用 POST"}, ensure_ascii=False))
        await writer.drain()
        writer.close()
        return

    log(f"update endpoint: {action}")
    code, body = await asyncio.get_running_loop().run_in_executor(None, _run_update, mapping[action])
    respond(code, body)
    await writer.drain()
    writer.close()


def _reason(code: int) -> str:
    return {200: "OK", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
            500: "Internal Server Error", 504: "Gateway Timeout"}.get(code, "OK")


async def handle_gateway_restart(up_path: str, headers, writer, from_root: bool = False) -> None:
    """接管 dashboard 的网关启停（restart / start / stop）→ 调 cmd/main 同名子命令。

    上游实现 spawn `hermes gateway {restart,start,stop}`，由它自己找进程、发信号；
    但本包的消息网关是**外部 supervisor**（cmd/main）托管的，进程生命周期只有一个
    所有者，上游那套不认识我们的 want 文件模型，直接放行会出现「重启后 supervisor
    与上游各拉一份 / 停不干净」。这里改为调 cmd/main 的 gateway-* 子命令：它写/删
    want 文件并启停 supervisor，进程归属唯一。**只动消息网关**，不动 dashboard /
    应用本身。

    返回 dashboard 期望的 ActionResponse：{name, ok, pid, message?}
    """
    # 端点 → cmd/main 子命令 + 动作名
    action = up_path.split("?")[0].rstrip("/").rsplit("/", 1)[-1]  # restart|start|stop
    _ACT = {
        "restart": ("gateway-restart", "gateway-restart", "网关已重启"),
        "start": ("gateway-start", "gateway-start", "网关已启动"),
        "stop": ("gateway-stop", "gateway-stop", "网关已停止"),
    }
    subcmd, name, ok_msg = _ACT.get(action, ("gateway-restart", "gateway-restart", "网关已重启"))
    def respond(code: int, body: dict) -> None:
        raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
        writer.write(
            f"HTTP/1.1 {code} {_reason(code)}\r\n"
            f"Content-Type: application/json; charset=utf-8\r\n"
            f"Content-Length: {len(raw)}\r\n"
            "Cache-Control: no-store\r\n"
            "Connection: close\r\n\r\n".encode("latin-1") + raw
        )

    if not _is_admin(headers, from_root):
        respond(403, {"ok": False, "message": "仅飞牛管理员可操作网关", "name": name})
        await writer.drain()
        writer.close()
        return

    main_sh = find_cmd_main()
    if not main_sh:
        respond(500, {"ok": False, "name": name,
                      "message": "找不到 cmd/main（应用生命周期脚本）"})
        await writer.drain()
        writer.close()
        return

    def _do() -> tuple[int, str]:
        try:
            proc = subprocess.run(["/bin/bash", main_sh, subcmd],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  timeout=90, check=False, text=True)
            return proc.returncode, proc.stdout.strip()
        except subprocess.TimeoutExpired:
            return 504, f"{action} 超时"
        except OSError as exc:
            return 500, f"无法执行：{exc}"

    code, out = await asyncio.get_running_loop().run_in_executor(None, _do)
    ok = code == 0
    # 登记真实结果：随后的 /api/actions/<name>/status 轮询据此返回 exit_code，
    # 避免前端把上游的 exit_code=null 误判成「操作失败」（见 _GATEWAY_ACTION_RESULTS 说明）。
    _record_gateway_action(name, code, out.splitlines() if out else [])
    resp = {"name": name, "pid": None, "ok": ok,
            "message": ok_msg if ok else f"网关{action}失败：{out[-200:]}"}
    respond(200 if ok else 500, resp)
    log(f"gateway {action} via cmd/main: ok={ok}")
    await writer.drain()
    writer.close()


async def handle_gateway_action_status(up_path: str, method: str, headers, writer,
                                       from_root: bool = False) -> bool:
    """接管 GET /api/actions/gateway-{restart,start,stop}/status。

    有近期登记 → 合成上游动作条期望的响应：{name, running:false, exit_code, pid, lines}。
    没有 / 已过期 → 返回 False，调用方回退走上游转发（行为与改动前一致）。

    返回 True 表示已自行应答（writer 已关闭）；False 表示未处理、请继续转发。
    """
    base = up_path.split("?")[0].rstrip("/")
    # /api/actions/<name>/status
    if not (base.startswith("/api/actions/") and base.endswith("/status")):
        return False
    name = base[len("/api/actions/"):-len("/status")]
    if name not in _GATEWAY_ACTION_NAMES:
        return False
    if not _is_admin(headers, from_root):
        return False  # 交给上游走它自己的鉴权/错误路径
    rec = _gateway_action_status(name)
    if rec is None:
        return False  # 没有我们的记录 → 回退上游，行为不变
    body = {
        "name": name,
        "running": False,
        "exit_code": rec["exit_code"],
        "pid": None,
        "lines": rec["lines"],
    }
    raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
    writer.write(
        f"HTTP/1.1 200 {_reason(200)}\r\n"
        f"Content-Type: application/json; charset=utf-8\r\n"
        f"Content-Length: {len(raw)}\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n\r\n".encode("latin-1") + raw
    )
    await writer.drain()
    writer.close()
    return True


async def handle_native_update_proxy(method: str, path: str, headers, writer, from_root: bool = False) -> None:
    """把 dashboard 原生更新入口接到本包的 hermes-update.py。

    上游 dashboard 期望：
      GET  /api/hermes/update/check → UpdateCheckResponse
        {install_method, current_version, behind, update_available,
         can_apply, update_command, message}
      POST /api/hermes/update       → ActionResponse
        {name, ok, pid, message?, update_command?}

    我们的 hermes-update.py 输出自己的 JSON，这里做字段映射。
    """
    def respond(code: int, body: dict) -> None:
        raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
        writer.write(
            f"HTTP/1.1 {code} {_reason(code)}\r\n"
            f"Content-Type: application/json; charset=utf-8\r\n"
            f"Content-Length: {len(raw)}\r\n"
            "Cache-Control: no-store\r\n"
            "Connection: close\r\n\r\n".encode("latin-1") + raw
        )

    if not _is_admin(headers, from_root):
        respond(403, {"ok": False, "message": "仅飞牛管理员可执行更新"})
        await writer.drain()
        writer.close()
        return

    loop = asyncio.get_running_loop()

    if path.endswith("/check"):
        # /system 首屏会**同步**调它，且和 9 个本地接口绑在同一个
        # Promise.allSettled 里 —— 只有全部 settle 才关转圈。
        # 所以这里绝不阻塞等待网络：
        #   命中缓存 → 立即返回真实结果；
        #   未命中   → **后台线程去查**，本次立即返回 update_available=null
        #              （前端按"未知"显示，不阻塞），下次访问即命中缓存。
        # 这样无论 GitHub 通不通，系统页都是瞬时打开。
        cached = _update_check_cached_or_none()
        if cached is not None:
            respond(200, cached)
        else:
            _kick_update_check_background()
            respond(200, {
                "install_method": "fnos-fpk",
                "current_version": "unknown",
                "behind": None,
                "update_available": None,   # 未知：后台正在查
                "can_apply": True,
                "update_command": "hermes-update apply",
                "message": "正在后台检查更新…",
            })
    else:
        code, body = await loop.run_in_executor(None, _run_update, "apply")
        try:
            d = json.loads(body)
        except ValueError:
            d = {"ok": False, "message": body[:200]}
        resp = {
            "name": "hermes-update",
            "ok": bool(d.get("ok")),
            "pid": None,
            "message": d.get("message") or ("更新完成" if d.get("ok") else "更新失败"),
            "update_command": "hermes-update apply",
        }
        if d.get("restart_required"):
            resp["message"] = (resp["message"] or "") + "（请重启应用生效）"
        respond(200 if d.get("ok") else 500, resp)

    await writer.drain()
    writer.close()


async def read_head(reader: asyncio.StreamReader):
    """读取并解析请求头。返回 (method, target, version, raw_headers, body_expected)。"""
    try:
        head = await reader.readuntil(b"\r\n\r\n")
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
        return None
    text = head.decode("latin-1")
    lines = text.split("\r\n")
    if not lines or not lines[0]:
        return None
    parts = lines[0].split(" ")
    if len(parts) < 3:
        return None
    method, target, version = parts[0], parts[1], parts[2]
    headers = []
    for line in lines[1:]:
        if not line:
            continue
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        headers.append((k.strip(), v.strip()))
    return method, target, version, headers


async def pump_body(client: asyncio.StreamReader, up: asyncio.StreamWriter, headers) -> None:
    """按 Content-Length / chunked 把请求体原样转发。"""
    hmap = {k.lower(): v for k, v in headers}
    te = hmap.get("transfer-encoding", "").lower()
    if "chunked" in te:
        while True:
            line = await client.readline()
            if not line:
                break
            up.write(line)
            try:
                size = int(line.split(b";")[0].strip() or b"0", 16)
            except ValueError:
                break
            if size == 0:
                # 尾随 CRLF / trailer，读到空行为止
                while True:
                    l = await client.readline()
                    up.write(l)
                    if l in (b"\r\n", b"\n", b""):
                        break
                break
            up.write(await client.readexactly(size + 2))
        await up.drain()
    elif "content-length" in hmap:
        try:
            n = int(hmap["content-length"])
        except ValueError:
            n = 0
        if n > 0:
            up.write(await client.readexactly(n))
            await up.drain()


async def pipe(a: asyncio.StreamReader, b: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await a.read(65536)
            if not data:
                break
            b.write(data)
            await b.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            b.close()
        except Exception:
            pass


async def handle(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter) -> None:
    peer = client_writer.get_extra_info("peername") or "local"
    # 对端进程 uid：飞牛网关以 root 运行，是本 socket 唯一可信来源。
    # 其它本机进程也能连（socket 0666），但它们不是 root ⇒ 伪造的 X-Trim-* 不被采信。
    p_uid = peer_uid(client_writer)
    from_root = p_uid == 0
    try:
        parsed = await read_head(client_reader)
        if not parsed:
            client_writer.close()
            return
        method, target, version, headers = parsed

        if REQUIRE_TRIM and not has_trim(headers):
            client_writer.write(
                b"HTTP/1.1 403 Forbidden\r\n"
                b"Content-Type: text/plain; charset=utf-8\r\n"
                b"Content-Length: 46\r\n"
                b"Connection: close\r\n\r\n"
                b"Only the fnOS unified gateway may reach this socket.\n"
            )
            await client_writer.drain()
            client_writer.close()
            return

        path, query = _split_target(target)
        up_path = strip_prefix(path) + query

        # 诊断：记录每个请求的路径 + 客户端 X-Forwarded-*。
        # 真机排查资源 404 的唯一现场证据 —— 能直接看出浏览器请求的是
        # /assets/（无前缀，说明 index.html 未改写）还是 /app/hermes/assets/。
        if DEBUG:
            xf = {k.lower(): v for k, v in headers if k.lower().startswith("x-forwarded-")}
            log(f"req {method} {path!r} → up={up_path!r} xfwd={xf}")

        # ── 入口兜底：把「前缀本身」重定向到 /sessions ──────────────
        #
        # 上游前端有竞态 bug：入口 URL 恰好等于 basename（无路径）时，
        # RootRedirect 刚跳到 /sessions，同一次 commit 里 ProfileProvider 的
        # ?profile= 同步 effect 用相对 navigate 把 URL 覆盖回根路径 →
        # <Routes> 无内容 → 页面只剩外壳（空白）。
        # 触发条件：路径前缀反代 + 入口 URL 正好是前缀本身 ——
        # fnOS 桌面图标的 url 就是 "/app/hermes"，故必现。
        #
        # 这里在代理层 302 到 <前缀>/sessions（保留 query），从入口就避开该状态。
        # 只对带 text/html 的 GET 生效（浏览器导航），不误伤 API/资源请求。
        if method == "GET" and PREFIX and path == PREFIX:
            accept = ""
            for k, v in headers:
                if k.lower() == "accept":
                    accept = v.lower()
                    break
            if "text/html" in accept:
                loc = f"{PREFIX}/sessions{query}"
                log(f"entry redirect {path!r} → {loc!r}")
                client_writer.write(
                    f"HTTP/1.1 302 Found\r\nLocation: {loc}\r\n"
                    f"Content-Length: 0\r\nCache-Control: no-store\r\n"
                    f"Connection: close\r\n\r\n".encode("latin-1")
                )
                await client_writer.drain()
                client_writer.close()
                return

        hmap = {k.lower(): v for k, v in headers}
        is_upgrade = (
            hmap.get("upgrade", "").lower() == "websocket"
            or "upgrade" in hmap.get("connection", "").lower()
        )

        # 更新控制端点：由代理本机处理，不转发给上游 dashboard。
        # 只有带 X-Trim-Isadmin（飞牛管理员）的请求才放行。
        if up_path == "/__hermes/update" or up_path.startswith("/__hermes/update/"):
            await handle_update_endpoint(method, up_path, headers, client_writer, from_root)
            return

        # 接管上游 dashboard 的原生更新入口 —— 转到本包的 hermes-update.py。
        # 原因：上游 `hermes update` 是 git 源码更新器，不认识本包「应用中心 + 外部
        # supervisor」的布局；且工作树里没有 .git，它只会报错退出。把 dashboard
        # 的按钮接到我们自己的 hermes-update.py（git 更新 + 重启应用），体验才连贯。
        _base_path = up_path.split("?")[0]
        if _base_path in ("/api/hermes/update", "/api/hermes/update/check"):
            await handle_native_update_proxy(method, _base_path, headers, client_writer, from_root)
            return

        # 接管 dashboard 的网关启停按钮（restart / start / stop）。
        # 原因：消息网关由 cmd/main 的外部 supervisor 托管，进程所有权必须唯一。
        # 上游这三个端点会自己 spawn/信号 `hermes gateway ...`，与 supervisor
        # 的 want 文件模型冲突（可能重启出两份、或停不掉）。官方 trim.hermes 用
        # Go wrapper 自己管进程；本包改为调 cmd/main 的 gateway-{restart,start,stop}
        # （由 cmd/main 的 supervisor 负责拉起/停止消息网关），归属单一。
        # 注意：只动消息网关，不动 dashboard / 代理 / 整个 fnOS 应用。
        if _base_path in ("/api/gateway/restart", "/api/gateway/start", "/api/gateway/stop") \
                and method == "POST":
            await handle_gateway_restart(up_path, headers, client_writer, from_root)
            return

        # 动作状态轮询：上游的 exit_code 只认它自己进程内的记录，而我们的网关动作
        # 由代理执行 → 上游返回 exit_code=null → 前端误报「操作失败」。若有本代理的
        # 登记就合成真实结果；否则回退上游转发（行为不变）。
        if method == "GET" and _base_path.startswith("/api/actions/"):
            if await handle_gateway_action_status(_base_path, method, headers, client_writer, from_root):
                return

        up_reader, up_writer = await asyncio.open_connection(UP_HOST, UP_PORT)

        # 组装转发头：剔除 hop-by-hop，改 Host，注入 X-Forwarded-*
        #
        # ⚠ WebSocket 握手必须**同时**带上 `Upgrade: websocket` 与
        #   `Connection: Upgrade` —— 上游（uvicorn/starlette）两者缺一就不回 101，
        #   客户端拿不到升级、依赖 WS 的页面（对话 / SYSTEM）直接黑屏。
        #   这里 Connection/Upgrade 都在 HOP_BY_HOP 里，所以要显式补回。
        out_lines = [f"{method} {up_path} {version}"]
        saw_host = False
        # 记录客户端原始 Host 与转发的协议，供下方 X-Forwarded-Host/Proto 使用。
        # 飞牛网关会带 X-Forwarded-Host / X-Forwarded-Proto（我们剥掉客户端那对
        # 以免重复），这里取它带来的值，没有则退回原始 Host。
        client_host = ""
        fwd_host = ""
        fwd_proto = ""
        for k, v in headers:
            lk = k.lower()
            if lk == "host":
                client_host = v
            elif lk == "x-forwarded-host":
                fwd_host = v
            elif lk == "x-forwarded-proto":
                fwd_proto = v
        for k, v in headers:
            lk = k.lower()
            if lk in HOP_BY_HOP:
                if is_upgrade and lk in ("upgrade", "connection"):
                    # 原样保留升级相关的这两个头
                    out_lines.append(f"{k}: {v}")
                continue
            if lk == "host":
                saw_host = True
                out_lines.append(f"Host: {UP_HOST}:{UP_PORT}")
                continue
            # 剔除客户端原有的 X-Forwarded-*：飞牛网关会带自己的
            # X-Forwarded-Prefix（可能是 "/" 或空），若原样转发再追加我们的，
            # 上游会收到重复头并取**第一个**（客户端那个）→ 前缀失效。
            # 前缀只能由本代理权威给出，见下方统一追加。
            if lk in ("x-forwarded-prefix", "x-forwarded-host", "x-forwarded-proto"):
                continue
            # ⚠ 仅对 **WebSocket 升级请求**剔除 Origin（HTTP 请求保留不动）。
            #
            # 为什么：上游 0.21.x 新增了 _ws_host_origin_reason（对应安全公告
            # GHSA-ppp5-vxwm-4cf7），要求 Origin 必须匹配 bound host；它通过
            # dashboard.public_url → trusted_public_hosts 判定，而本包未配该值
            # （配了会触发 OAuth 门禁、锁死 dashboard）→ 经反向代理访问时浏览器
            # 带的外部域名 Origin 一律被拒 → WS 握手 403 → 对话/SYSTEM 页黑屏。
            #
            # 上游对该校验的实现是 `if not origin: return None`（无 Origin 直接
            # 放行）—— 这是它为反代/非浏览器客户端预留的路径。而 0.20.2 及更早
            # 版本**根本没有此校验**，剔除 Origin 等于回到旧版安全基线。
            #
            # 不削弱鉴权：WS 的真实凭据是 URL 里的 ?token=<会话 token>（浏览器
            # 请求自带），攻击者拿不到 token 仍连不上；前置还有飞牛统一网关的
            # 登录态（X-Trim-*）。失去的仅是 Origin 这一层的 DNS-rebinding 防护。
            if is_upgrade and lk == "origin":
                if DEBUG:
                    log(f"WS: stripped Origin {v!r}")
                continue
            out_lines.append(f"{k}: {v}")
        if not saw_host:
            out_lines.append(f"Host: {UP_HOST}:{UP_PORT}")
        # 关键：告诉 Hermes 它挂在 /app/hermes 下（唯一权威来源）
        if PREFIX:
            out_lines.append(f"X-Forwarded-Prefix: {PREFIX}")
        # X-Forwarded-Host/Proto：上游据此生成绝对 URL（cookie 的 Secure 标志、
        # OAuth 回调 url_for、重定向）。当前 dashboard 不做 auth 门，影响有限；
        # 但一旦启用 dashboard auth 而这两个头缺失，回调 URL 会按
        # http://127.0.0.1:9119 生成 → 浏览器完成不了回调 → 登录死循环。
        # 取客户端原始 Host（等价于浏览器看到的域名），协议优先用网关给的值。
        if fwd_host or client_host:
            out_lines.append(f"X-Forwarded-Host: {fwd_host or client_host}")
        out_lines.append(f"X-Forwarded-Proto: {fwd_proto or 'http'}")
        if not is_upgrade:
            out_lines.append("Connection: close")

        up_writer.write(("\r\n".join(out_lines) + "\r\n\r\n").encode("latin-1"))
        await up_writer.drain()

        if is_upgrade:
            # WebSocket：双向原样管道
            await pump_body(client_reader, up_writer, headers)
            await asyncio.gather(
                pipe(client_reader, up_writer),
                pipe(up_reader, client_writer),
            )
            return

        await pump_body(client_reader, up_writer, headers)

        # 响应：原样流式回传（已强制 Connection: close，读到 EOF 即可）。
        #
        # 这里**不做 HTML 改写**：资源前缀已由构建时的 Vite base 编译进
        # index.html 与各 chunk（见 scripts/web-build.mjs），代理只需纯转发。
        # 早期版本曾在此处改写 HTML —— 那是错误方向（改不到 JS 内部拼接的
        # 懒加载路径），已移除。
        while True:
            chunk = await up_reader.read(65536)
            if not chunk:
                break
            client_writer.write(chunk)
            await client_writer.drain()
        client_writer.close()
        try:
            up_writer.close()
        except Exception:
            pass
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    except Exception as exc:  # noqa: BLE001
        log(f"error from {peer}: {exc!r}")
        try:
            if not client_writer.is_closing():
                client_writer.write(
                    b"HTTP/1.1 502 Bad Gateway\r\n"
                    b"Content-Type: text/plain; charset=utf-8\r\n"
                    b"Content-Length: 44\r\n"
                    b"Connection: close\r\n\r\n"
                    b"Hermes backend not ready; restart the app.\n"
                )
                await client_writer.drain()
        except Exception:
            pass
    finally:
        try:
            if not client_writer.is_closing():
                client_writer.close()
        except Exception:
            pass


async def main() -> None:
    if not SOCKET_PATH and not TCP_PORT:
        log("HERMES_GATEWAY_SOCKET is required (or HERMES_GATEWAY_TCP_PORT for debug)")
        sys.exit(1)

    if TCP_PORT:
        server = await asyncio.start_server(handle, "127.0.0.1", TCP_PORT)
        log(f"listening tcp:127.0.0.1:{TCP_PORT} → http://{UP_HOST}:{UP_PORT} (prefix={PREFIX or '/'})")
    else:
        try:
            if os.path.exists(SOCKET_PATH):
                os.unlink(SOCKET_PATH)
        except OSError:
            pass
        os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
        server = await asyncio.start_unix_server(handle, path=SOCKET_PATH)
        try:
            os.chmod(SOCKET_PATH, 0o666)
        except OSError:
            pass
        log(f"listening unix:{SOCKET_PATH} → http://{UP_HOST}:{UP_PORT} (prefix={PREFIX or '/'})")

    stop = asyncio.Event()

    def _shutdown(*_a):
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, _shutdown)
        except (NotImplementedError, RuntimeError):
            pass

    async with server:
        await stop.wait()
    log("shutting down")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

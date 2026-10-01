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
import subprocess
import sys
import time

SOCKET_PATH = os.environ.get("HERMES_GATEWAY_SOCKET", "")
PREFIX = os.environ.get("HERMES_GATEWAY_PREFIX", "/app/hermes").rstrip("/")
UP_HOST = os.environ.get("HERMES_UPSTREAM_HOST", "127.0.0.1")
UP_PORT = int(os.environ.get("HERMES_UPSTREAM_PORT", "9119") or "9119")
REQUIRE_TRIM = os.environ.get("HERMES_GATEWAY_REQUIRE_TRIM", "0") == "1"
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


def _update_script_path() -> str:
    if UPDATE_SCRIPT and os.path.exists(UPDATE_SCRIPT):
        return UPDATE_SCRIPT
    # 默认：与代理同目录
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "hermes-update.py")


def _is_admin(headers) -> bool:
    for k, v in headers:
        if k.lower() == "x-trim-isadmin":
            return v.strip().lower() in ("1", "true", "yes")
    return False


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



def _run_update(action: str) -> tuple[int, str]:
    script = _update_script_path()
    if not os.path.exists(script):
        return 500, json.dumps({"ok": False, "message": f"缺少更新脚本：{script}"}, ensure_ascii=False)
    py = sys.executable or "python3"
    try:
        proc = subprocess.run(
            [py, script, action],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=3600, check=False, text=True,
        )
        body = proc.stdout.strip()
        # 脚本输出是 JSON；原样透传
        return (200 if proc.returncode == 0 else 500), body
    except subprocess.TimeoutExpired:
        return 504, json.dumps({"ok": False, "message": "更新操作超时"}, ensure_ascii=False)
    except OSError as exc:
        return 500, json.dumps({"ok": False, "message": f"无法执行更新脚本：{exc}"}, ensure_ascii=False)


async def handle_update_endpoint(method: str, up_path: str, headers, writer) -> None:
    def respond(code: int, body: str, ctype: str = "application/json; charset=utf-8") -> None:
        raw = body.encode("utf-8")
        writer.write(
            f"HTTP/1.1 {code} {_reason(code)}\r\n"
            f"Content-Type: {ctype}\r\n"
            f"Content-Length: {len(raw)}\r\n"
            "Cache-Control: no-store\r\n"
            "Connection: close\r\n\r\n".encode("latin-1") + raw
        )

    if not _is_admin(headers):
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


async def handle_native_update_proxy(method: str, path: str, headers, writer) -> None:
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

    if not _is_admin(headers):
        respond(403, {"ok": False, "message": "仅飞牛管理员可执行更新"})
        await writer.drain()
        writer.close()
        return

    loop = asyncio.get_running_loop()

    if path.endswith("/check"):
        code, body = await loop.run_in_executor(None, _run_update, "check")
        try:
            d = json.loads(body)
        except ValueError:
            d = {"ok": False, "message": body[:200]}
        resp = {
            "install_method": "fnos-fpk",
            "current_version": d.get("current_version") or "unknown",
            "behind": None,
            "update_available": bool(d.get("available")),
            "can_apply": True,   # 本包自管更新，随时可应用
            "update_command": "hermes-update apply",
            "message": d.get("message") or (
                f"可更新到 {d.get('ref')}" if d.get("available") else "已是最新版本"
            ),
        }
        respond(200, resp)
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

        hmap = {k.lower(): v for k, v in headers}
        is_upgrade = (
            hmap.get("upgrade", "").lower() == "websocket"
            or "upgrade" in hmap.get("connection", "").lower()
        )

        # 更新控制端点：由代理本机处理，不转发给上游 dashboard。
        # 只有带 X-Trim-Isadmin（飞牛管理员）的请求才放行。
        if up_path == "/__hermes/update" or up_path.startswith("/__hermes/update/"):
            await handle_update_endpoint(method, up_path, headers, client_writer)
            return

        # 接管上游 dashboard 的原生更新入口 —— 转到本包的 hermes-update.py。
        # 原因：上游 `hermes update` 是 git 源码更新器，且要 venv/PM 布局；
        # 本包是"自带 CPython + site-packages"，靠 install-stamp.json 的
        # updateMechanism=external 让上游拒绝自更新。把 dashboard 的按钮接到
        # 我们自己的更新链路，用户体验才连贯。
        _base_path = up_path.split("?")[0]
        if _base_path in ("/api/hermes/update", "/api/hermes/update/check"):
            await handle_native_update_proxy(method, _base_path, headers, client_writer)
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
            out_lines.append(f"{k}: {v}")
        if not saw_host:
            out_lines.append(f"Host: {UP_HOST}:{UP_PORT}")
        # 关键：告诉 Hermes 它挂在 /app/hermes 下
        if PREFIX:
            out_lines.append(f"X-Forwarded-Prefix: {PREFIX}")
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

        # 响应：原样流式回传（已强制 Connection: close，读到 EOF 即可）
        first = True
        while True:
            chunk = await up_reader.read(65536)
            if not chunk:
                break
            client_writer.write(chunk)
            await client_writer.drain()
            first = False
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

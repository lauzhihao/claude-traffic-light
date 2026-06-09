#!/usr/bin/env python3
"""Claude 红绿灯 · Mac agent(多会话聚合 · tailnet 版)

驻留在「插着灯的那台机器」上的后台进程:
  - 监听 CLAUDE_LIGHT_BIND:PORT(默认 127.0.0.1:7321;多机同步时设 0.0.0.0)
  - 接收**所有机器、所有会话**的 hook 状态上报(本机 + tailnet 上的其它机器)
  - 按会话聚合,优先级 Y > R > G:
      任一会话在等你(Y) → 黄;否则任一在推理(R) → 红;
      否则全部完成/空闲(G) → 绿;一个会话都没有 → 灭(0)
  - 把聚合结果写 USB 串口(红绿灯)
  - 崩溃/强杀且没触发清理的会话,用超时剔除,避免把灯永久卡红/卡黄
  - 安全:/event、/health 只接受本机(127/::1)和 Tailscale(100.64.0.0/10)来源
  - (保留)扫 quota、轮询中继命令、tmux 注入 —— iOS 相关,未配环境变量时自动空转

零外部依赖,纯 stdlib。
"""

import glob
import ipaddress
import json
import os
import sys
import time
import threading
import subprocess
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# ---- 配置(环境变量)----
RELAY_URL = os.environ.get("CLAUDE_LIGHT_RELAY_URL", "").rstrip("/")
UPDATE_SECRET = os.environ.get("CLAUDE_LIGHT_UPDATE_SECRET", "")
COMMAND_SECRET = os.environ.get("CLAUDE_LIGHT_COMMAND_SECRET", "")
# Cloudflare 默认 UA 'Python-urllib/x' 会被边缘 WAF 当机器人直接 403,
# 给中继请求带个正常 UA 绕过(curl 能过就是因为 UA 不同)。
HTTP_USER_AGENT = "claude-traffic-light-agent/1.0"
TMUX_TARGET = os.environ.get("CLAUDE_LIGHT_TMUX_TARGET", "claude")
LISTEN_BIND = os.environ.get("CLAUDE_LIGHT_BIND", "127.0.0.1")  # 多机同步设 0.0.0.0
LISTEN_PORT = int(os.environ.get("CLAUDE_LIGHT_AGENT_PORT", "7321"))
SERIAL_GLOB = os.environ.get("CLAUDE_LIGHT_SERIAL", "/dev/cu.usbmodem*")
CLAUDE_PROJECTS_DIR = Path(os.environ.get(
    "CLAUDE_PROJECTS_DIR",
    str(Path.home() / ".claude" / "projects"),
))
QUOTA_INTERVAL_S = 30
COMMAND_POLL_S = 1
SESSION_STALE_S = int(os.environ.get("CLAUDE_LIGHT_SESSION_STALE_S", "600"))
R_STALE_S = int(os.environ.get("CLAUDE_LIGHT_R_STALE_S", "60"))   # R(推理)无心跳超时→降级 G(应对 ESC 中断不触发任何 hook)
LIGHT_REFRESH_S = 3        # 强制重发间隔=灯拔插后最大恢复延迟;每次仅 glob+1字节串口写,开销可忽略

# 优先级:数字大者优先。Y(等你)> R(推理)> G(完成)
PRIORITY = {"Y": 3, "R": 2, "G": 1}

# 允许的来源:本机 + Tailscale CGNAT 段
_TAILNET = ipaddress.ip_network("100.64.0.0/10")

# ---- 运行时状态 ----
state_lock = threading.Lock()
sessions = {}              # {session_id: {"state": "R"/"Y"/"G", "ts": float}}
last_serial = None         # 上次写入串口的聚合值,变化时才重写
current_quota = {}
stats = {"pings": 0}       # 诊断计数:收到的心跳数,看 /health


def client_allowed(ip):
    if ip in ("127.0.0.1", "::1", "localhost"):
        return True
    try:
        return ipaddress.ip_address(ip) in _TAILNET
    except Exception:
        return False


# ---- 配额计算(保留;未配中继时不扫)----

def parse_iso_ts(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def scan_quota():
    if not CLAUDE_PROJECTS_DIR.exists():
        return {}
    now = time.time()
    cutoff_5h = now - 5 * 3600
    cutoff_7d = now - 7 * 86400
    tokens_5h = 0
    tokens_7d = 0
    for jsonl_path in CLAUDE_PROJECTS_DIR.rglob("*.jsonl"):
        try:
            if jsonl_path.stat().st_mtime < cutoff_7d:
                continue
            with jsonl_path.open() as f:
                for line in f:
                    try:
                        entry = json.loads(line)
                    except Exception:
                        continue
                    ts_raw = entry.get("timestamp")
                    if not ts_raw:
                        continue
                    t = parse_iso_ts(ts_raw)
                    if t is None or t < cutoff_7d:
                        continue
                    usage = (entry.get("message") or {}).get("usage") or {}
                    total = (
                        usage.get("input_tokens", 0)
                        + usage.get("output_tokens", 0)
                        + usage.get("cache_read_input_tokens", 0)
                        + usage.get("cache_creation_input_tokens", 0)
                    )
                    tokens_7d += total
                    if t >= cutoff_5h:
                        tokens_5h += total
        except Exception as e:
            print(f"[quota] skip {jsonl_path}: {e}", file=sys.stderr)
    return {
        "tokens5h": tokens_5h,
        "tokens7d": tokens_7d,
        "updatedAt": int(now),
    }


def quota_loop():
    global current_quota
    if not RELAY_URL:
        return  # 配额只用于中继(iOS)推送;没配中继就不扫,省得反复读一堆 jsonl
    while True:
        try:
            current_quota = scan_quota()
        except Exception as e:
            print(f"[quota_loop] {e}", file=sys.stderr)
        time.sleep(QUOTA_INTERVAL_S)


# ---- 串口输出 ----

def write_serial(state):
    for dev in glob.glob(SERIAL_GLOB):
        try:
            with open(dev, "wb") as f:
                f.write(state.encode())
            return True
        except Exception:
            continue
    return False


# ---- 会话聚合 + 刷新灯 ----

def summarize_sessions():
    with state_lock:
        return {sid[:8]: s["state"] for sid, s in sessions.items()}


def aggregate_state():
    """剔除过期会话,返回 Y/R/G 聚合值;一个会话都没有则返回 '0'(灭)。

    两级超时:① 任何会话超过 SESSION_STALE_S 直接剔除(防崩溃会话永久占灯);
    ② R(推理)会话超过 R_STALE_S 没有心跳/事件 → 降级为 G。ESC 中断不触发任何
    hook,靠 ② 把"卡红"在 ~R_STALE_S 内放掉;真在干活时工具调用的心跳(PING)会
    不停刷新 ts,所以不会被误降级。
    """
    now = time.time()
    best, best_pri = None, 0
    with state_lock:
        for sid in list(sessions):
            age = now - sessions[sid]["ts"]
            if age > SESSION_STALE_S:
                del sessions[sid]
                continue
            if sessions[sid]["state"] == "R" and age > R_STALE_S:
                sessions[sid]["state"] = "G"   # 不再推理(中断/回合悄悄结束)→ 当作完成/空闲
        for s in sessions.values():
            pri = PRIORITY.get(s["state"], 0)
            if pri > best_pri:
                best_pri, best = pri, s["state"]
    return best or "0"


def refresh_light(force=False):
    """重算聚合并刷新灯。

    - 状态真正变化时:写串口 + 推中继 + 打日志。
    - force=True(周期兜底):无条件再写一次串口,但不重复推中继/打日志。
      用来兜住"灯被拔插/复位后丢状态"——固件开机自检后会归 0(灭),而
      agent 这边聚合值没变就不会主动补发,于是灯一直停在灭。周期强制重发
      让重新插上的灯最多 LIGHT_REFRESH_S 秒自动恢复到当前状态。
    """
    global last_serial
    agg = aggregate_state()
    changed = agg != last_serial
    if changed or force:
        write_serial(agg)
    if changed:
        last_serial = agg
        threading.Thread(target=push_state, args=(agg,), daemon=True).start()
        print(f"[light] -> {agg}   sessions={summarize_sessions()}", file=sys.stderr)
    return agg


def light_loop():
    # 每周期强制重发当前状态(force=True):灯拔插/复位后固件归 0、agent 状态
    # 没变就不会主动补发,这里兜底让灯自动恢复。配合固件"同状态字节忽略",
    # 稳态下重发是空操作,不会打断红呼吸/黄慢闪的动画。
    while True:
        try:
            refresh_light(force=True)
        except Exception as e:
            print(f"[light_loop] {e}", file=sys.stderr)
        time.sleep(LIGHT_REFRESH_S)


def set_session(session_id, state):
    sid = session_id or "default"
    with state_lock:
        sessions[sid] = {"state": state, "ts": time.time()}


def drop_session(session_id):
    sid = session_id or "default"
    with state_lock:
        sessions.pop(sid, None)


# ---- 推送到中继(保留;未配 RELAY_URL/UPDATE_SECRET 时直接返回)----

def push_state(state):
    if not RELAY_URL or not UPDATE_SECRET:
        return
    if state not in ("R", "Y", "G"):
        return
    body = {"state": state, "secret": UPDATE_SECRET, "quota": current_quota}
    try:
        req = urllib.request.Request(
            f"{RELAY_URL}/update",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json", "User-Agent": HTTP_USER_AGENT},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            resp.read()
    except Exception as e:
        print(f"[push_state] {e}", file=sys.stderr)


# ---- tmux 命令注入(保留;iOS 遥控批准用,未配中继时 command_loop 不启动)----

def tmux_send(*keys):
    try:
        subprocess.run(
            ["tmux", "send-keys", "-t", TMUX_TARGET, *keys],
            check=True, timeout=2,
        )
    except Exception as e:
        print(f"[tmux] send {keys} -> {e}", file=sys.stderr)


def execute_command(cmd):
    action = cmd.get("action")
    if action == "approve":
        tmux_send("y", "Enter")
    elif action == "deny":
        tmux_send("n", "Enter")
    elif action == "stop":
        tmux_send("Escape", "Escape")
    else:
        print(f"[cmd] unknown action {action}", file=sys.stderr)


def command_loop():
    if not RELAY_URL or not COMMAND_SECRET:
        return
    while True:
        try:
            req = urllib.request.Request(
                f"{RELAY_URL}/commands?secret={COMMAND_SECRET}",
                headers={"User-Agent": HTTP_USER_AGENT},
                method="GET",
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())
                for cmd in data.get("commands", []):
                    execute_command(cmd)
        except Exception:
            pass  # 网络抖动是常态
        time.sleep(COMMAND_POLL_S)


# ---- HTTP 入口:接收各机各会话 hook 事件 ----

class HookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if not client_allowed(self.client_address[0]):
            self._respond(403); return
        if self.path != "/event":
            self._respond(404); return

        length = int(self.headers.get("Content-Length", 0))
        try:
            event = json.loads(self.rfile.read(length))
        except Exception:
            self._respond(400); return

        state = event.get("state")
        hook = event.get("hook") or {}
        session_id = hook.get("session_id")

        if state == "PRE":
            self._respond(200); return

        if state == "PING":
            # 心跳(来自工具 Pre/PostToolUse):刷新会话 ts,保住 R 不被 R_STALE_S 降级。
            # 只刷新已存在会话、不改颜色、不新建——即便和 AskUserQuestion→Y 同时触发也不抢色。
            stats["pings"] += 1
            sid = session_id or "default"
            with state_lock:
                if sid in sessions:
                    sessions[sid]["ts"] = time.time()
            self._respond(200); return

        if state == "START":
            set_session(session_id, "G")
            refresh_light(); self._respond(200); return
        if state == "END":
            drop_session(session_id)
            refresh_light(); self._respond(200); return

        if state not in ("R", "Y", "G"):
            self._respond(400); return

        set_session(session_id, state)
        refresh_light()
        self._respond(200)

    def do_GET(self):
        if not client_allowed(self.client_address[0]):
            self._respond(403); return
        if self.path == "/health":
            agg = aggregate_state()
            body = json.dumps({
                "ok": True,
                "aggregate": agg,
                "sessions": summarize_sessions(),
                "quota": current_quota,
                "serial_glob": SERIAL_GLOB,
                "bind": f"{LISTEN_BIND}:{LISTEN_PORT}",
                "relay": bool(RELAY_URL),
                "pings": stats["pings"],
                "r_stale_s": R_STALE_S,
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self._respond(404)

    def _respond(self, code):
        self.send_response(code)
        self.end_headers()

    def log_message(self, *args):
        pass  # 静音


# ---- 入口 ----

def main():
    print(f"[agent] listening on {LISTEN_BIND}:{LISTEN_PORT}")
    print(f"[agent] serial glob: {SERIAL_GLOB}")
    print(f"[agent] relay: {RELAY_URL or '(not configured)'}")
    print(f"[agent] priority: Y > R > G   stale cutoff: {SESSION_STALE_S}s")

    # 启动即把灯归到"无会话=灭"
    refresh_light()

    # 后台线程:配额扫描(仅配了中继才跑)、命令轮询、灯超时刷新
    threading.Thread(target=quota_loop, daemon=True).start()
    threading.Thread(target=command_loop, daemon=True).start()
    threading.Thread(target=light_loop, daemon=True).start()

    # 立刻开始监听,不被初始配额扫描阻塞(launchd 下 IO 受限会拖死启动)
    server = HTTPServer((LISTEN_BIND, LISTEN_PORT), HookHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[agent] stopped")


if __name__ == "__main__":
    main()

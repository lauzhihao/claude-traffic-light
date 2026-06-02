#!/usr/bin/env python3
"""Claude 红绿灯 · Mac agent

驻留在 Mac 上的后台进程：
  - 监听 localhost:7321/event，接收 hook 上报的状态事件
  - 周期解析 ~/.claude/projects/**/conversation_*.jsonl 计算 5h/7d token 用量
  - 把状态 + 配额 + 待批准操作 POST 到 Cloudflare 中继
  - 轮询中继的命令队列，把 iOS 发来的 approve/deny 通过 tmux send-keys 注入到 Claude
  - 顺手把状态字节写到 USB 串口（如果硬件红绿灯插着）

零外部依赖，纯 stdlib。
"""

import glob
import json
import os
import sys
import time
import uuid
import threading
import subprocess
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# ---- 配置（环境变量）----
RELAY_URL = os.environ.get("CLAUDE_LIGHT_RELAY_URL", "").rstrip("/")
UPDATE_SECRET = os.environ.get("CLAUDE_LIGHT_UPDATE_SECRET", "")
COMMAND_SECRET = os.environ.get("CLAUDE_LIGHT_COMMAND_SECRET", "")
TMUX_TARGET = os.environ.get("CLAUDE_LIGHT_TMUX_TARGET", "claude")
LISTEN_PORT = int(os.environ.get("CLAUDE_LIGHT_AGENT_PORT", "7321"))
SERIAL_GLOB = os.environ.get("CLAUDE_LIGHT_SERIAL", "/dev/tty.usbmodem*")
CLAUDE_PROJECTS_DIR = Path(os.environ.get(
    "CLAUDE_PROJECTS_DIR",
    str(Path.home() / ".claude" / "projects"),
))
QUOTA_INTERVAL_S = 30
COMMAND_POLL_S = 1

# ---- 运行时状态 ----
state_lock = threading.Lock()
current_quota = {}             # {tokens5h, tokens7d, updatedAt}
last_tool_seen = None          # {tool, preview, ts}  from PreToolUse
pending_request = None         # {id, tool, preview, ts}  当 state == Y 时


# ---- 配额计算 ----

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
    while True:
        try:
            current_quota = scan_quota()
        except Exception as e:
            print(f"[quota_loop] {e}", file=sys.stderr)
        time.sleep(QUOTA_INTERVAL_S)


# ---- 推送到中继 ----

def push_state(state):
    if not RELAY_URL or not UPDATE_SECRET:
        return
    with state_lock:
        body = {
            "state": state,
            "secret": UPDATE_SECRET,
            "quota": current_quota,
        }
        if state == "Y" and pending_request:
            body["pending"] = {
                "id": pending_request["id"],
                "tool": pending_request["tool"],
                "preview": pending_request["preview"],
            }
    try:
        req = urllib.request.Request(
            f"{RELAY_URL}/update",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            resp.read()
    except Exception as e:
        print(f"[push_state] {e}", file=sys.stderr)


# ---- 串口输出（顺手）----

def write_serial(state):
    for dev in glob.glob(SERIAL_GLOB):
        try:
            with open(dev, "wb") as f:
                f.write(state.encode())
            return
        except Exception:
            continue


# ---- tmux 命令注入 ----

def tmux_send(*keys):
    try:
        subprocess.run(
            ["tmux", "send-keys", "-t", TMUX_TARGET, *keys],
            check=True, timeout=2,
        )
    except Exception as e:
        print(f"[tmux] send {keys} -> {e}", file=sys.stderr)


def execute_command(cmd):
    global pending_request
    action = cmd.get("action")
    cmd_id = cmd.get("id")

    with state_lock:
        active = pending_request
    if active and active["id"] != cmd_id:
        print(f"[cmd] stale {cmd_id}, current={active['id']}", file=sys.stderr)
        return

    # Claude Code 的工具批准 TUI 默认接受 y/n 或方向键，按你版本调整
    if action == "approve":
        tmux_send("y", "Enter")
    elif action == "deny":
        tmux_send("n", "Enter")
    elif action == "stop":
        tmux_send("Escape", "Escape")
    else:
        print(f"[cmd] unknown action {action}", file=sys.stderr)
        return

    with state_lock:
        if pending_request and pending_request["id"] == cmd_id:
            pending_request = None


def command_loop():
    if not RELAY_URL or not COMMAND_SECRET:
        return
    while True:
        try:
            req = urllib.request.Request(
                f"{RELAY_URL}/commands?secret={COMMAND_SECRET}",
                method="GET",
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())
                for cmd in data.get("commands", []):
                    execute_command(cmd)
        except Exception:
            pass  # 网络抖动是常态
        time.sleep(COMMAND_POLL_S)


# ---- HTTP 入口：接收 hook 事件 ----

def preview_for(tool_input):
    if isinstance(tool_input, dict):
        # Bash 的 command 字段最常用，挑出来更友好
        if "command" in tool_input:
            return str(tool_input["command"])[:120]
        if "file_path" in tool_input:
            return str(tool_input["file_path"])[:120]
        return json.dumps(tool_input)[:120]
    return str(tool_input)[:120]


class HookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        global pending_request, last_tool_seen
        if self.path != "/event":
            self._respond(404); return

        length = int(self.headers.get("Content-Length", 0))
        try:
            event = json.loads(self.rfile.read(length))
        except Exception:
            self._respond(400); return

        state = event.get("state")
        hook = event.get("hook") or {}

        if state == "PRE":
            tool = hook.get("tool_name", "")
            preview = preview_for(hook.get("tool_input"))
            if tool:
                with state_lock:
                    last_tool_seen = {"tool": tool, "preview": preview, "ts": time.time()}
            self._respond(200); return

        if state not in ("R", "Y", "G"):
            self._respond(400); return

        with state_lock:
            if state == "Y":
                # 用最近一次 PreToolUse 的工具信息（30s 内有效）
                if last_tool_seen and time.time() - last_tool_seen["ts"] < 30:
                    pending_request = {
                        "id": uuid.uuid4().hex[:8],
                        "tool": last_tool_seen["tool"],
                        "preview": last_tool_seen["preview"],
                        "ts": time.time(),
                    }
                else:
                    pending_request = {
                        "id": uuid.uuid4().hex[:8],
                        "tool": "input",
                        "preview": "Claude 在等待输入",
                        "ts": time.time(),
                    }
            else:
                pending_request = None
                last_tool_seen = None

        write_serial(state)
        threading.Thread(target=push_state, args=(state,), daemon=True).start()
        self._respond(200)

    def do_GET(self):
        if self.path == "/health":
            with state_lock:
                body = json.dumps({
                    "ok": True,
                    "quota": current_quota,
                    "pending": pending_request,
                    "relay": bool(RELAY_URL),
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
    print(f"[agent] listening on 127.0.0.1:{LISTEN_PORT}")
    print(f"[agent] relay: {RELAY_URL or '(not configured)'}")
    print(f"[agent] tmux target: {TMUX_TARGET}")
    print(f"[agent] claude projects dir: {CLAUDE_PROJECTS_DIR}")

    # 启动时跑一次
    global current_quota
    current_quota = scan_quota()
    print(f"[agent] initial quota: 5h={current_quota.get('tokens5h', 0):,}  7d={current_quota.get('tokens7d', 0):,}")

    threading.Thread(target=quota_loop, daemon=True).start()
    threading.Thread(target=command_loop, daemon=True).start()

    server = HTTPServer(("127.0.0.1", LISTEN_PORT), HookHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[agent] stopped")


if __name__ == "__main__":
    main()

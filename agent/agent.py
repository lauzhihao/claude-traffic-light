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
  - 安全:/event 只接受本机(127/::1)和 Tailscale(100.64.0.0/10)来源;
    /register(有 secret)和 /health(只读)额外放行私网段,手机经家庭 Wi-Fi 可达
  - iOS 推送:内置 APNs 中继(apns.py)——手机 POST /register 注册 Live Activity
    token,状态变化直推 Apple,不再绕道 Cloudflare(也就不再依赖本地代理)。
    未配 APNS 环境变量/缺依赖时推送自动空转,纯本地灯不受影响。

核心纯 stdlib;仅 iOS 推送需要 agent/.venv(httpx[http2] + cryptography),见 apns.py。
"""

import glob
import ipaddress
import json
import os
import sys
import time
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import apns

# ---- 配置(环境变量)----
REGISTER_SECRET = os.environ.get("CLAUDE_LIGHT_REGISTER_SECRET", "")
LISTEN_BIND = os.environ.get("CLAUDE_LIGHT_BIND", "127.0.0.1")  # 多机同步设 0.0.0.0
LISTEN_PORT = int(os.environ.get("CLAUDE_LIGHT_AGENT_PORT", "7321"))
SERIAL_GLOB = os.environ.get("CLAUDE_LIGHT_SERIAL", "/dev/cu.usbmodem*")
CLAUDE_PROJECTS_DIR = Path(os.environ.get(
    "CLAUDE_PROJECTS_DIR",
    str(Path.home() / ".claude" / "projects"),
))
QUOTA_INTERVAL_S = 30
SESSION_STALE_S = int(os.environ.get("CLAUDE_LIGHT_SESSION_STALE_S", "600"))
R_STALE_S = int(os.environ.get("CLAUDE_LIGHT_R_STALE_S", "60"))   # R(推理)无心跳超时→降级 G(应对 ESC 中断不触发任何 hook)
LIGHT_REFRESH_S = 3        # 强制重发间隔=灯拔插后最大恢复延迟;每次仅 glob+1字节串口写,开销可忽略
PUSH_REFRESH_S = int(os.environ.get("CLAUDE_LIGHT_PUSH_REFRESH_S", "600"))  # 周期重推 APNs:错过变化推送的手机最多此间隔后自愈

# 优先级:数字大者优先。Y(等你)> R(推理)> G(完成)
PRIORITY = {"Y": 3, "R": 2, "G": 1}

# 允许的来源:本机 + Tailscale CGNAT 段(没有配置文件时的回退)
_TAILNET = ipaddress.ip_network("100.64.0.0/10")
# 手机不装 Tailscale 时经家庭局域网注册/读状态。仅 /register(有 secret 把门)
# 和 /health(只读)放行私网段;/event 仍只收本机+tailnet,防局域网设备伪造灯态。
_LAN_NETS = [ipaddress.ip_network(n) for n in
             ("192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12")]

# ---- 配置文件:master(亮灯机)/ slaves(允许上报状态的远程机器白名单)----
# 路径:env CLAUDE_LIGHT_CONFIG,默认 ~/.config/claude-traffic-light/config.json
# 格式: {"master": "100.x.x.x", "slaves": ["100.x.x.x", ...]}
# 行为:配了 → 只接收 本机(127) + master + slaves(白名单);没配 → 回退接收整个 tailnet。
CONFIG_PATH = os.environ.get(
    "CLAUDE_LIGHT_CONFIG",
    str(Path.home() / ".config" / "claude-traffic-light" / "config.json"),
)


def load_peers():
    """读配置文件,返回白名单(master+slaves)集合;无文件返回 None(=回退 tailnet)。"""
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
    except FileNotFoundError:
        return None
    except Exception as e:
        print(f"[config] 读 {CONFIG_PATH} 失败,回退 tailnet: {e}", file=sys.stderr)
        return None
    peers = set()
    if cfg.get("master"):
        peers.add(str(cfg["master"]).strip())
    for s in (cfg.get("slaves") or []):
        if str(s).strip():
            peers.add(str(s).strip())
    return peers or None


ALLOWED_PEERS = load_peers()   # None = 没配置文件,回退 tailnet 全收

# ---- 运行时状态 ----
state_lock = threading.Lock()
sessions = {}              # {session_id: {"state": "R"/"Y"/"G", "ts": float}}
last_serial = None         # 上次写入串口的聚合值,变化时才重写
current_quota = {}
stats = {"pings": 0}       # 诊断计数:收到的心跳数,看 /health


def client_allowed(ip, lan_ok=False):
    if ip in ("127.0.0.1", "::1", "localhost"):
        return True                       # 本机(master 自己的状态走回环)永远允许
    if not lan_ok and ALLOWED_PEERS is not None:
        return ip in ALLOWED_PEERS        # /event 配了 master/slaves:白名单,只收这些机器的状态
    # /register(有 secret 把门)/health(只读)不受白名单约束:
    # 手机不是"上报状态的机器",经 tailnet 或家庭私网都放行。
    try:
        addr = ipaddress.ip_address(ip)
    except Exception:
        return False
    if addr in _TAILNET:
        return True
    return lan_ok and any(addr in net for net in _LAN_NETS)


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
    if not apns.enabled():
        return  # 配额只随 iOS 推送下发;推送没启用就不扫,省得反复读一堆 jsonl
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
    #
    # 同理每 PUSH_REFRESH_S 向手机重推一次当前状态(实体灯兜底的对偶):
    # 哪次变化推送没送达(手机离线/APNs 抖动),最多一个周期后自愈,
    # 不再永久停在旧颜色。同内容重推手机端只是原样重渲染,无感。
    last_push_refresh = time.time()
    while True:
        try:
            agg = refresh_light(force=True)
            if time.time() - last_push_refresh >= PUSH_REFRESH_S:
                last_push_refresh = time.time()
                if agg in ("R", "Y", "G"):
                    threading.Thread(target=push_state, args=(agg,), daemon=True).start()
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


# ---- iOS 推送(本地 APNs 直推;未配 APNS 环境变量时空转)----

def push_state(state):
    """把状态直推到所有已注册的手机 Live Activity。

    失败重试 2 次(1s/3s 退避):状态翻转频繁,单次推送丢失会让手机
    永久停在旧颜色直到下一次状态变化——这正是 Cloudflare 时代"灯卡绿"
    的根源,本地直推 + 重试 + light_loop 周期重推三层兜底。
    """
    if not apns.enabled():
        return
    if state not in ("R", "Y", "G"):
        return
    content_state = {"state": state, "updatedAt": int(time.time())}
    if current_quota:
        content_state["quota"] = current_quota
    for attempt, backoff in ((1, 1), (2, 3), (3, 0)):
        try:
            results = apns.push_all(content_state)
            bad = [r for r in results if r["status"] not in (200, 400, 410)]
            if not bad:
                return
            print(f"[push_state] attempt {attempt}: {bad}", file=sys.stderr)
        except Exception as e:
            print(f"[push_state] attempt {attempt}: {e}", file=sys.stderr)
        if backoff:
            time.sleep(backoff)


# ---- HTTP 入口:接收各机各会话 hook 事件 ----

class HookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/register":
            if not client_allowed(self.client_address[0], lan_ok=True):
                self._respond(403); return
            self._handle_register(); return
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

    def _handle_register(self):
        """iOS App 注册 Live Activity push token(原 Cloudflare /register)。
        注册成功立即回推当前状态:App 一打开,灵动岛秒同步,不用等下次变化。"""
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length))
        except Exception:
            self._respond(400); return
        if not REGISTER_SECRET or body.get("secret") != REGISTER_SECRET:
            self._respond(401); return
        token = body.get("token")
        if not token:
            self._respond(400); return
        if not apns.enabled():
            print(f"[register] rejected: apns disabled ({apns.disabled_reason()})",
                  file=sys.stderr)
            self._respond(503); return
        n = apns.register_token(token)
        print(f"[register] token {token[:8]}… ({n} total)", file=sys.stderr)
        agg = aggregate_state()
        if agg in ("R", "Y", "G"):
            threading.Thread(target=push_state, args=(agg,), daemon=True).start()
        self._respond_json({"ok": True, "tokens": n})

    def do_GET(self):
        if not client_allowed(self.client_address[0], lan_ok=(self.path == "/health")):
            self._respond(403); return
        if self.path == "/health":
            agg = aggregate_state()
            self._respond_json({
                "ok": True,
                "aggregate": agg,
                "sessions": summarize_sessions(),
                "quota": current_quota,
                "serial_glob": SERIAL_GLOB,
                "bind": f"{LISTEN_BIND}:{LISTEN_PORT}",
                "apns": {"enabled": apns.enabled(),
                         "reason": apns.disabled_reason(),
                         "env": apns.APNS_ENV,
                         "tokens": apns.token_count() if apns.enabled() else 0},
                "peers": sorted(ALLOWED_PEERS) if ALLOWED_PEERS is not None else "tailnet+lan(未配置文件)",
                "pings": stats["pings"],
                "r_stale_s": R_STALE_S,
                # iOS App fetchLatest() 兼容(原 worker /health 的形状):
                # 无会话(灭)对手机就是"空闲",报 G。
                "latest": {"state": agg if agg in ("R", "Y", "G") else "G",
                           "updatedAt": int(time.time())},
            })
        else:
            self._respond(404)

    def _respond(self, code):
        self.send_response(code)
        self.end_headers()

    def _respond_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # 静音


# ---- 入口 ----

def main():
    print(f"[agent] listening on {LISTEN_BIND}:{LISTEN_PORT}")
    print(f"[agent] serial glob: {SERIAL_GLOB}")
    apns_desc = (f"enabled ({apns.APNS_ENV}, {apns.token_count()} tokens)"
                 if apns.enabled() else f"disabled ({apns.disabled_reason()})")
    print(f"[agent] apns push: {apns_desc}")
    print(f"[agent] priority: Y > R > G   stale cutoff: {SESSION_STALE_S}s")

    # 启动即把灯归到"无会话=灭"
    refresh_light()

    # 后台线程:配额扫描(仅启用推送才跑)、灯超时刷新+周期重推
    threading.Thread(target=quota_loop, daemon=True).start()
    threading.Thread(target=light_loop, daemon=True).start()

    # 立刻开始监听,不被初始配额扫描阻塞(launchd 下 IO 受限会拖死启动)
    server = HTTPServer((LISTEN_BIND, LISTEN_PORT), HookHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[agent] stopped")


if __name__ == "__main__":
    main()

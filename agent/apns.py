"""APNs Live Activity 直推 —— 本地中继,取代 Cloudflare Worker。

agent 自己持有 Apple 推送私钥(.p8),签 ES256 JWT 后经 HTTP/2 直推
api.push.apple.com,手机锁屏/灵动岛即时更新。之前绕道 Cloudflare 的唯一
原因是"需要一个服务端持钥调 APNs",但状态的唯一生产者就是本机,中继
放本地反而少一跳出境网络(workers.dev 必须走代理,APNs 国内直连可达)。

依赖(装在 agent/.venv,见 README):
    httpx[http2]    APNs 强制 HTTP/2,stdlib urllib 不支持
    cryptography    ES256(ECDSA P-256)签名

环境变量(缺任一则 enabled()=False,agent 退化为纯本地灯,不影响串口):
    CLAUDE_LIGHT_APNS_P8         .p8 私钥文件路径
    CLAUDE_LIGHT_APNS_KEY_ID     Apple 10 位 Key ID
    CLAUDE_LIGHT_APNS_TEAM_ID    Apple 10 位 Team ID
    CLAUDE_LIGHT_APNS_BUNDLE_ID  主 App Bundle ID
    CLAUDE_LIGHT_APNS_ENV        development | production(默认 development)

token 落盘 ~/.claude-light/tokens.json,Apple 返回 400/410 时自动剔除。
"""

import json
import os
import sys
import threading
import time
from pathlib import Path

try:
    import httpx
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils as ec_utils
    _DEPS_OK = True
except ImportError as e:
    _DEPS_OK = False
    _DEPS_ERR = str(e)

P8_PATH = os.environ.get("CLAUDE_LIGHT_APNS_P8", "")
KEY_ID = os.environ.get("CLAUDE_LIGHT_APNS_KEY_ID", "")
TEAM_ID = os.environ.get("CLAUDE_LIGHT_APNS_TEAM_ID", "")
BUNDLE_ID = os.environ.get("CLAUDE_LIGHT_APNS_BUNDLE_ID", "")
APNS_ENV = os.environ.get("CLAUDE_LIGHT_APNS_ENV", "development")

TOKENS_PATH = Path(os.environ.get(
    "CLAUDE_LIGHT_TOKENS_PATH",
    str(Path.home() / ".claude-light" / "tokens.json"),
))

_HOST = ("api.push.apple.com" if APNS_ENV == "production"
         else "api.development.push.apple.com")

_lock = threading.Lock()
_jwt = None
_jwt_exp = 0.0
_key = None
_client = None


def enabled():
    if not _DEPS_OK:
        return False
    return bool(P8_PATH and KEY_ID and TEAM_ID and BUNDLE_ID)


def disabled_reason():
    if not _DEPS_OK:
        return f"missing deps: {_DEPS_ERR}"
    missing = [n for n, v in [
        ("CLAUDE_LIGHT_APNS_P8", P8_PATH), ("CLAUDE_LIGHT_APNS_KEY_ID", KEY_ID),
        ("CLAUDE_LIGHT_APNS_TEAM_ID", TEAM_ID), ("CLAUDE_LIGHT_APNS_BUNDLE_ID", BUNDLE_ID),
    ] if not v]
    return f"missing env: {', '.join(missing)}" if missing else ""


# ---- token 存储 ----

def _load_tokens():
    try:
        return json.loads(TOKENS_PATH.read_text())
    except Exception:
        return {}


def _save_tokens(tokens):
    TOKENS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = TOKENS_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(tokens, indent=2))
    tmp.replace(TOKENS_PATH)


def register_token(token):
    with _lock:
        tokens = _load_tokens()
        tokens[token] = {"registeredAt": int(time.time())}
        _save_tokens(tokens)
    return len(tokens)


def token_count():
    with _lock:
        return len(_load_tokens())


# ---- JWT(ES256,缓存 50 分钟;Apple 要求 20-60 分钟内复用)----

def _b64url(data):
    import base64
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _get_jwt():
    global _jwt, _jwt_exp, _key
    now = time.time()
    with _lock:
        if _jwt and _jwt_exp - now > 600:
            return _jwt
        if _key is None:
            _key = serialization.load_pem_private_key(
                Path(P8_PATH).read_bytes(), password=None,
            )
        header = _b64url(json.dumps(
            {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
        payload = _b64url(json.dumps(
            {"iss": TEAM_ID, "iat": int(now)}).encode())
        signing_input = f"{header}.{payload}".encode()
        der_sig = _key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
        # JWT 要的是 r||s 各 32 字节定长拼接,不是 DER
        r, s = ec_utils.decode_dss_signature(der_sig)
        raw_sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        _jwt = f"{signing_input.decode()}.{_b64url(raw_sig)}"
        _jwt_exp = now + 3000
        return _jwt


def _get_client():
    global _client
    with _lock:
        if _client is None:
            # trust_env=False:APNs 国内直连可达,显式绕开 HTTPS_PROXY 之类
            # 残留环境变量,这正是 Cloudflare 时代丢推送的根源。
            # timeout 收紧到 5s:连接假死时尽早失败、交给重连,别一发卡满 10s。
            # keepalive_expiry=20s:国内长连接常被中间设备/GFW 静默掐死,复用半死
            # 连接会每发都超时;限制 idle 存活,宁可重连(新建 TCP 实测 ~300ms)也不
            # 赌一条可能已死的连接——这是"手机长时间停在旧状态"的根因。
            _client = httpx.Client(
                http2=True, trust_env=False,
                timeout=httpx.Timeout(5.0),
                limits=httpx.Limits(keepalive_expiry=20.0),
            )
        return _client


def _reset_client():
    """丢弃当前(疑似假死的)连接,下次 _get_client 重建。"""
    global _client
    with _lock:
        c, _client = _client, None
    if c is not None:
        try:
            c.close()
        except Exception:
            pass


# ---- 推送 ----

def push_all(content_state, priority=10):
    """向所有已注册 token 推一次 Live Activity 更新。

    priority:APNs apns-priority。10=即时投递、全额计入 Apple 的 Live Activity
    预算桶(用于用户可见的转场);5=系统可延迟/合并、极省预算(用于高频抖动期
    的尾推)。持续 churn 全用 10 会抽干预算→被限流丢弃→手机卡帧。

    返回 [{"token": 前8位, "status": http状态码或异常名}];
    Apple 答 400/410(token 失效/已注销)时就地剔除该 token。
    """
    with _lock:
        tokens = _load_tokens()
    if not tokens:
        return []

    jwt = _get_jwt()
    client = _get_client()
    payload = json.dumps({
        "aps": {
            "timestamp": content_state.get("updatedAt", int(time.time())),
            "event": "update",
            "content-state": content_state,
        },
    })
    headers = {
        "authorization": f"bearer {jwt}",
        "apns-topic": f"{BUNDLE_ID}.push-type.liveactivity",
        "apns-push-type": "liveactivity",
        "apns-priority": str(priority),
        "content-type": "application/json",
    }

    results, dead = [], []
    for token in list(tokens):
        url = f"https://{_HOST}/3/device/{token}"
        status = None
        # 两次尝试:第一次失败(多半是连接假死)立即重建连接再试一次。
        # 这样即便本轮第一个 token 撞上死连接,也只多花一次 5s 超时,后面的 token
        # 全走新连接;配合 agent 侧 push_state 的 2 次重试,稳态丢推送基本绝迹。
        for attempt in (1, 2):
            try:
                resp = client.post(url, content=payload, headers=headers)
                status = resp.status_code
                if status in (400, 410):
                    dead.append(token)
                break
            except Exception as e:
                status = type(e).__name__
                _reset_client()          # 连接可能已死,丢弃重建
                client = _get_client()   # 第二次尝试用新连接
        results.append({"token": token[:8] + "…", "status": status})

    if dead:
        with _lock:
            tokens = _load_tokens()
            for t in dead:
                tokens.pop(t, None)
            _save_tokens(tokens)
        print(f"[apns] pruned {len(dead)} dead token(s)", file=sys.stderr)

    return results

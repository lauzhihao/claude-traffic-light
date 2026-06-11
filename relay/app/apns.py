"""APNs Live Activity 直推(异步版,中继用)。

复用 agent/apns.py 已打磨并经对抗审查的逻辑,改为 asyncio + 多 token 批量:
  - ES256(.p8)签 JWT,缓存 50 分钟(Apple 要求 20-60 分钟内复用,否则 429)。
  - httpx HTTP/2(APNs 强制),trust_env=False 绕开残留代理。
  - 连接假死自愈:timeout 5s + keepalive_expiry 20s + 失败即重建连接重试一次
    (国内/跨境长连接被中间设备静默掐死时,别赌半死连接)。
  - priority 透传:10=即时投递(leading/转场),5=系统可合并、极省 Live Activity
    配额(trailing/抖动期)。由调用方(agent 客户端)决定,中继只转发。

环境变量(缺任一 → enabled()=False,中继 /v1/state 返回 503,不影响注册):
  RELAY_APNS_P8         .p8 私钥路径
  RELAY_APNS_KEY_ID     Apple 10 位 Key ID
  RELAY_APNS_TEAM_ID    Apple 10 位 Team ID
  RELAY_APNS_BUNDLE_ID  App Bundle ID
  RELAY_APNS_ENV        production | sandbox(默认 production;Xcode debug 装的 App 用 sandbox)
"""

import asyncio
import base64
import json
import os
import time
from pathlib import Path

try:
    import httpx
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils as ec_utils
    _DEPS_OK, _DEPS_ERR = True, ""
except ImportError as e:  # pragma: no cover
    _DEPS_OK, _DEPS_ERR = False, str(e)

P8_PATH = os.environ.get("RELAY_APNS_P8", "")
KEY_ID = os.environ.get("RELAY_APNS_KEY_ID", "")
TEAM_ID = os.environ.get("RELAY_APNS_TEAM_ID", "")
BUNDLE_ID = os.environ.get("RELAY_APNS_BUNDLE_ID", "")
APNS_ENV = os.environ.get("RELAY_APNS_ENV", "production")

_HOST = ("api.push.apple.com" if APNS_ENV == "production"
         else "api.sandbox.push.apple.com")


def enabled():
    return bool(_DEPS_OK and P8_PATH and KEY_ID and TEAM_ID and BUNDLE_ID
               and Path(P8_PATH).is_file())


def disabled_reason():
    if not _DEPS_OK:
        return f"missing deps: {_DEPS_ERR}"
    missing = [n for n, v in [
        ("RELAY_APNS_P8", P8_PATH), ("RELAY_APNS_KEY_ID", KEY_ID),
        ("RELAY_APNS_TEAM_ID", TEAM_ID), ("RELAY_APNS_BUNDLE_ID", BUNDLE_ID),
    ] if not v]
    if missing:
        return "missing env: " + ", ".join(missing)
    if not Path(P8_PATH).is_file():
        return f".p8 not found: {P8_PATH}"
    return ""


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class APNs:
    """单例:持私钥、缓存 JWT、复用一条(失败即重建的)HTTP/2 连接。"""

    def __init__(self):
        self._key = None
        self._jwt = None
        self._jwt_exp = 0.0
        self._jwt_lock = asyncio.Lock()
        self._client = None
        self._client_lock = asyncio.Lock()

    async def _get_jwt(self) -> str:
        now = time.time()
        if self._jwt and self._jwt_exp - now > 600:
            return self._jwt
        async with self._jwt_lock:
            if self._jwt and self._jwt_exp - now > 600:
                return self._jwt
            if self._key is None:
                self._key = serialization.load_pem_private_key(
                    Path(P8_PATH).read_bytes(), password=None)
            header = _b64url(json.dumps(
                {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
            payload = _b64url(json.dumps(
                {"iss": TEAM_ID, "iat": int(now)}).encode())
            signing_input = f"{header}.{payload}".encode()
            der = self._key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
            r, s = ec_utils.decode_dss_signature(der)
            raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
            self._jwt = f"{signing_input.decode()}.{_b64url(raw)}"
            self._jwt_exp = now + 3000   # 50 分钟
            return self._jwt

    async def _get_client(self):
        if self._client is not None:
            return self._client
        async with self._client_lock:
            if self._client is None:
                self._client = httpx.AsyncClient(
                    http2=True, trust_env=False,
                    timeout=httpx.Timeout(5.0),
                    limits=httpx.Limits(keepalive_expiry=20.0))
            return self._client

    async def _reset_client(self):
        async with self._client_lock:
            c, self._client = self._client, None
        if c is not None:
            try:
                await c.aclose()
            except Exception:
                pass

    async def push(self, tokens, content_state, priority=10):
        """向一批 device token 推同一条更新。

        返回 [(token, status)];status 为 HTTP 码或异常类名。调用方据 400/410 剔除死 token。
        """
        if not tokens:
            return []
        jwt = await self._get_jwt()
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
        results = []
        for token in tokens:
            url = f"https://{_HOST}/3/device/{token}"
            status = None
            for attempt in (1, 2):   # 失败一次→重建连接再试一次
                client = await self._get_client()
                try:
                    resp = await client.post(url, content=payload, headers=headers)
                    status = resp.status_code
                    break
                except Exception as e:
                    status = type(e).__name__
                    await self._reset_client()
            results.append((token, status))
        return results

    async def aclose(self):
        await self._reset_client()

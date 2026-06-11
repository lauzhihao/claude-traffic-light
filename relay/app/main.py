"""Claude 红绿灯 · 多租户推送中继(自托管)

替代当年的 Cloudflare Worker:部署在自己的服务器(够得到 APNs 的出口),持 .p8、
按用户隔离地把状态推到各自的 Live Activity。每用户一个 api_token(管理员发),
iOS app 和 agent 都带它标识身份。

接口(契约见 README):
  GET  /v1/health                 健康/状态(无鉴权)
  POST /v1/register               {deviceToken}            注册当前用户的设备 token
  POST /v1/state                  {state, priority?, quota?} 推当前用户的所有设备
  POST /v1/admin/users            {name}  (X-Admin-Secret)  建用户,返回 api_token
  GET  /v1/admin/users            (X-Admin-Secret)          列用户 + 设备数
  DELETE /v1/admin/users/{id}     (X-Admin-Secret)          删用户(级联删其设备)

鉴权:用户接口要 `Authorization: Bearer <api_token>`(或 body.apiToken 兜底);
管理员接口要 `X-Admin-Secret: <RELAY_ADMIN_SECRET>`。
"""

import os
import time
from collections import deque

from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel

import apns
import store

ADMIN_SECRET = os.environ.get("RELAY_ADMIN_SECRET", "")
# 防滥用限频:每用户滑动窗口(默认 60s 内最多 120 次 /v1/state)。远高于 agent 节流后的
# 合理速率(leading+trailing),只拦真正的刷接口行为;超限返回 429。
RATE_WINDOW_S = float(os.environ.get("RELAY_RATE_WINDOW_S", "60"))
RATE_MAX = int(os.environ.get("RELAY_RATE_MAX", "120"))

app = FastAPI(title="claude-light relay", version="1.0")
_store = store.Store()
_apns = apns.APNs() if apns.enabled() else None

# 内存态(进程内,重启即丢——无妨,agent 600s 周期重推会补)
_last_state = {}          # user_id -> content_state(注册时回推,开 app 秒同步)
_rate = {}                # user_id -> deque[timestamps]


# ---- 鉴权 ----

def _auth_user(request: Request, authorization, body_token=None):
    token = None
    if authorization and authorization.lower().startswith("bearer "):
        token = authorization[7:].strip()
    token = token or body_token
    user = _store.user_by_token(token) if token else None
    if not user:
        raise HTTPException(401, "invalid or missing api token")
    return user


def _auth_admin(secret):
    if not ADMIN_SECRET:
        raise HTTPException(503, "admin disabled (RELAY_ADMIN_SECRET unset)")
    if secret != ADMIN_SECRET:
        raise HTTPException(403, "bad admin secret")


def _rate_ok(user_id):
    now = time.time()
    dq = _rate.setdefault(user_id, deque())
    while dq and now - dq[0] > RATE_WINDOW_S:
        dq.popleft()
    if len(dq) >= RATE_MAX:
        return False
    dq.append(now)
    return True


# ---- 模型 ----

class RegisterBody(BaseModel):
    deviceToken: str
    apiToken: str | None = None


class StateBody(BaseModel):
    state: str
    priority: int | None = None
    quota: dict | None = None
    apiToken: str | None = None


class AdminUserBody(BaseModel):
    name: str = ""


# ---- 用户接口 ----

@app.get("/v1/health")
async def health():
    return {
        "ok": True,
        "apns": {"enabled": apns.enabled(), "reason": apns.disabled_reason(),
                 "env": apns.APNS_ENV},
        **_store.counts(),
    }


@app.post("/v1/register")
async def register(body: RegisterBody, authorization: str | None = Header(None)):
    user = _auth_user(None, authorization, body.apiToken)
    if not body.deviceToken or len(body.deviceToken) > 400:
        raise HTTPException(400, "bad deviceToken")
    _store.add_device(user["id"], body.deviceToken)
    # 注册即回推该用户最近状态(开 app 秒同步);没有缓存则跳过,等下次 /v1/state
    cs = _last_state.get(user["id"])
    if cs and _apns:
        await _apns.push([body.deviceToken], cs, priority=10)
    return {"ok": True}


@app.post("/v1/state")
async def state(body: StateBody, authorization: str | None = Header(None)):
    user = _auth_user(None, authorization, body.apiToken)
    if body.state not in ("R", "Y", "G"):
        raise HTTPException(400, "state must be R/Y/G")
    if not _rate_ok(user["id"]):
        raise HTTPException(429, "rate limited")
    if not _apns:
        raise HTTPException(503, f"apns disabled: {apns.disabled_reason()}")

    content_state = {"state": body.state, "updatedAt": int(time.time())}
    if body.quota:
        content_state["quota"] = body.quota
    _last_state[user["id"]] = content_state

    priority = body.priority if body.priority in (5, 10) else 10
    tokens = _store.devices_for(user["id"])
    results = await _apns.push(tokens, content_state, priority=priority)

    dead = [t for t, s in results if s in (400, 410)]
    if dead:
        _store.remove_devices(user["id"], dead)
    ok = sum(1 for _, s in results if s == 200)
    return {"ok": True, "pushed": ok, "devices": len(tokens), "pruned": len(dead)}


# ---- 管理员接口 ----

@app.post("/v1/admin/users")
async def admin_create_user(body: AdminUserBody,
                            x_admin_secret: str | None = Header(None)):
    _auth_admin(x_admin_secret)
    return _store.create_user(body.name)   # 含 api_token,只在创建时返回一次


@app.get("/v1/admin/users")
async def admin_list_users(x_admin_secret: str | None = Header(None)):
    _auth_admin(x_admin_secret)
    return {"users": _store.list_users()}   # 不含 api_token


@app.delete("/v1/admin/users/{user_id}")
async def admin_delete_user(user_id: int, x_admin_secret: str | None = Header(None)):
    _auth_admin(x_admin_secret)
    ok = _store.delete_user(user_id)
    _last_state.pop(user_id, None)
    _rate.pop(user_id, None)
    if not ok:
        raise HTTPException(404, "no such user")
    return {"ok": True}

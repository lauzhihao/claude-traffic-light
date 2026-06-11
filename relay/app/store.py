"""多租户存储(SQLite)。

两张表:
  users   —— 每用户一个不透明 api_token(管理员发);iOS app 和 agent 都用它标识身份。
  devices —— 用户名下注册的 Live Activity push token(一个用户可多设备/多活动)。

隔离保证:所有读写都以 user_id 为界,api_token → 唯一 user;一个用户的请求只能
注册/影响自己的 device token,拿不到也动不了别人的(不知道别人的 api_token)。

并发:sqlite3 连接 check_same_thread=False + 一把进程级 Lock 串行化写;FastAPI 在
线程池/事件循环里调用时由调用方 asyncio.to_thread 包一层,避免阻塞事件循环。
"""

import os
import secrets
import sqlite3
import threading
import time

DB_PATH = os.environ.get("RELAY_DB", "/data/relay.db")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT,
    api_token  TEXT UNIQUE NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
    user_id       INTEGER NOT NULL,
    device_token  TEXT NOT NULL,
    registered_at INTEGER NOT NULL,
    last_seen     INTEGER NOT NULL,
    PRIMARY KEY (user_id, device_token),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
"""


class Store:
    def __init__(self, path=DB_PATH):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA foreign_keys=ON")
        self._lock = threading.Lock()
        with self._lock:
            self._db.executescript(_SCHEMA)
            self._db.commit()

    # ---- 用户(管理员)----

    def create_user(self, name=""):
        token = "clt_" + secrets.token_urlsafe(32)
        with self._lock:
            cur = self._db.execute(
                "INSERT INTO users(name, api_token, created_at) VALUES(?,?,?)",
                (name, token, int(time.time())))
            self._db.commit()
            return {"id": cur.lastrowid, "name": name, "api_token": token}

    def user_by_token(self, api_token):
        if not api_token:
            return None
        with self._lock:
            row = self._db.execute(
                "SELECT id, name FROM users WHERE api_token=?", (api_token,)).fetchone()
        return dict(row) if row else None

    def list_users(self):
        with self._lock:
            rows = self._db.execute(
                "SELECT u.id, u.name, u.created_at, "
                "  (SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id) AS devices "
                "FROM users u ORDER BY u.id").fetchall()
        return [dict(r) for r in rows]

    def delete_user(self, user_id):
        with self._lock:
            cur = self._db.execute("DELETE FROM users WHERE id=?", (user_id,))
            self._db.commit()
            return cur.rowcount > 0

    # ---- 设备 token ----

    def add_device(self, user_id, device_token):
        now = int(time.time())
        with self._lock:
            self._db.execute(
                "INSERT INTO devices(user_id, device_token, registered_at, last_seen) "
                "VALUES(?,?,?,?) "
                "ON CONFLICT(user_id, device_token) DO UPDATE SET last_seen=excluded.last_seen",
                (user_id, device_token, now, now))
            self._db.commit()

    def devices_for(self, user_id):
        with self._lock:
            rows = self._db.execute(
                "SELECT device_token FROM devices WHERE user_id=?", (user_id,)).fetchall()
        return [r["device_token"] for r in rows]

    def remove_devices(self, user_id, tokens):
        if not tokens:
            return
        with self._lock:
            self._db.executemany(
                "DELETE FROM devices WHERE user_id=? AND device_token=?",
                [(user_id, t) for t in tokens])
            self._db.commit()

    def counts(self):
        with self._lock:
            u = self._db.execute("SELECT COUNT(*) c FROM users").fetchone()["c"]
            d = self._db.execute("SELECT COUNT(*) c FROM devices").fetchone()["c"]
        return {"users": u, "devices": d}

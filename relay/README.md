# 推送中继(自托管 · 多租户)

公开版的 APNs 出口。部署在**够得到 Apple 推送服务器**的机器上(实测出口
`154.201.79.83` 洛杉矶,57ms 触达 `api.push.apple.com`),持 `.p8`、按用户隔离地
把状态推到各自的 Live Activity。

> 为什么不是各人各自直推?APNs 的 `.p8` 是**开发者团队**凭据,普通用户没有、也
> 不该拿到(泄露=全员被冒充/key 被吊销)。所以公开版必须:**一把 key 锁在中心
> 服务器后面,按用户鉴权对外**。这不是当年那个被墙的 Cloudflare Worker——是搬到
> 自己服务器、加多租户、走真域名 HTTPS 的版本。推送量从不是瓶颈(APNs 配额按
> 每设备每活动算,不按 key 算);要解决的是密钥安全 + 多租户鉴权。

## 架构

```
用户A 的 iOS app ─┐                              ┌─ APNs ─→ 用户A 的 iPhone
用户A 的 Mac agent ┼─ HTTPS ─→  中继(本机)  ─┤  (持 .p8, 缓存 1 个 JWT,
用户B 的 ...       ─┘   apn.vooice.tech         └─   按 user→device 分发, priority 透传)
                       (nginx → 127.0.0.1:8088
                        → docker: uvicorn)
```

- **鉴权**:每用户一个 `api_token`(管理员发)。iOS app(注册设备 token)和 Mac
  agent(上报状态)都带它。`api_token → 唯一 user`,只能动自己名下的设备,拿不到
  也碰不到别人的。
- **节流**:留在 agent 客户端(它已会 leading/trailing,并知道哪发是 leading)——
  agent 把 `priority`(10=即时/leading,5=合并省配额/trailing)随状态发来,中继只
  转发。中继侧另有一道**按用户限频**(默认 60s/120 次)防滥用。
- **连接健壮**:中继复用一条 HTTP/2 连接,失败即重建重试(同 `agent/apns.py` 的
  连接假死自愈),避免长连接被中间设备掐死后一连串丢推。

## 接口契约

| 方法 | 路径 | 鉴权 | body | 说明 |
|---|---|---|---|---|
| `GET` | `/v1/health` | 无 | — | `{ok, apns:{enabled,reason,env}, users, devices}` |
| `POST` | `/v1/register` | `Authorization: Bearer <api_token>` | `{deviceToken}` | 注册/刷新当前用户的 Live Activity push token;有缓存态则立即回推(开 app 秒同步) |
| `POST` | `/v1/state` | `Authorization: Bearer <api_token>` | `{state, priority?, quota?}` | `state`∈`R/Y/G`;`priority`∈`5/10`(缺省 10);推该用户所有设备,400/410 死 token 自动剔除 |
| `POST` | `/v1/admin/users` | `X-Admin-Secret` | `{name}` | 建用户,**返回 `api_token`(只此一次)** |
| `GET` | `/v1/admin/users` | `X-Admin-Secret` | — | 列用户 + 设备数(不含 token) |
| `DELETE` | `/v1/admin/users/{id}` | `X-Admin-Secret` | — | 删用户(级联删设备) |

`api_token` 也可放在 body 的 `apiToken` 字段(给不便设 header 的客户端兜底)。

## 部署(在出口服务器上)

前提:已装 Docker + nginx + certbot;`.p8` 已拷到服务器(如
`/root/claude-light/AuthKey_XXX.p8`,`chmod 600`)。

```bash
# 1. 取代码
git clone <repo> && cd claude-traffic-light/relay

# 2. 配置
cp .env.example .env && vim .env          # 填 KEY_ID/TEAM_ID/BUNDLE_ID/ENV、.p8 路径、ADMIN_SECRET
#   ADMIN_SECRET 用 openssl rand -hex 32 生成

# 3. DNS:在 Cloudflare 给 apn.vooice.tech 加一条 A → <出口服务器 IP>
#    先设「仅 DNS」(灰云),好让 certbot HTTP-01 直连验证;签完证书可按需再开橙云代理。

# 4. 证书
certbot certonly --webroot -w /var/www/html -d apn.vooice.tech

# 5. nginx
cp deploy/nginx-apn.vooice.tech.conf /etc/nginx/conf.d/
nginx -t && systemctl reload nginx        # 只新增本站点,不动其它 server 块

# 6. 起服务
docker compose up -d --build
curl -s https://apn.vooice.tech/v1/health   # 看 apns.enabled=true
```

### 发一个用户的 api_token

```bash
curl -s -X POST https://apn.vooice.tech/v1/admin/users \
  -H "X-Admin-Secret: $RELAY_ADMIN_SECRET" \
  -H "Content-Type: application/json" -d '{"name":"liuzhihao"}'
# -> {"id":1,"name":"liuzhihao","api_token":"clt_xxxxx"}  ← 记下来,只返回这一次
```

## 客户端怎么接(后续改造)

- **iOS app**:`RelayConfig` 增加 `apiToken`;注册改为 `POST https://apn.vooice.tech/v1/register`
  带 `Authorization: Bearer <api_token>`、body `{deviceToken}`(不再注册到本机 agent)。
- **Mac agent**:`push_state` 由「本地 `apns.push_all` 直推」改为「`POST /v1/state` 上报
  `{state, priority, quota}` 带 Bearer」。`apns.py` 的本地直推可保留作自托管模式开关。
  节流逻辑(leading/trailing → priority)原样保留,只是出口从 Apple 换成中继。

> 两端用**同一个 api_token** 才能把「这个人的手机」和「这个人的状态」对上。

## 安全

- `.p8` 只在服务器、只读挂载、不进仓库;容器非 root 运行。
- 用户接口强制 Bearer;一个 `api_token` 只能影响自己名下设备(多租户隔离)。
- 管理员接口靠 `X-Admin-Secret`;务必随机且只在服务端持有。
- 容器只绑 `127.0.0.1:8088`,对外仅经 nginx TLS;按用户限频防刷。
- `.env` / `data/`(sqlite)/ `*.p8` 均已 gitignore。

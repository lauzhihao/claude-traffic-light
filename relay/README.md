# Cloudflare Worker · APNs 中继

接收 Mac hook 的 `/update` 和 iOS App 的 `/register`，转成 APNs 推送。

## 一次性部署

前置：装好 Node.js 和 `npx`。Apple Developer 账号必须已经申请下来并拿到了：
- `.p8` Auth Key 文件
- Key ID（10 位字符串）
- Team ID（10 位字符串）
- Bundle ID（你定的，如 `com.yourname.claudetrafficlight`）

### 1. 装依赖

```bash
cd relay
npm install
```

### 2. 登录 Cloudflare

```bash
npx wrangler login
```

### 3. 创建 KV 存推送 token + 命令队列

```bash
npx wrangler kv:namespace create STORE
```

把命令打印出来的 `id` 复制到 `wrangler.toml` 的 `REPLACE_WITH_KV_ID` 位置。

### 4. 改 `wrangler.toml`

把 `APNS_BUNDLE_ID` 改成你的真实 Bundle ID。

### 5. 注入 6 个 secret

```bash
npx wrangler secret put APNS_KEY_P8          # 粘贴 .p8 文件全文（含 BEGIN/END）
npx wrangler secret put APNS_KEY_ID          # 10 位 Key ID
npx wrangler secret put APNS_TEAM_ID         # 10 位 Team ID
npx wrangler secret put REGISTER_SECRET      # iOS App 注册 push token 用
npx wrangler secret put UPDATE_SECRET        # Mac agent 推状态用
npx wrangler secret put COMMAND_SECRET       # iOS 发命令 + Mac agent 取命令用
```

三个 SECRET 自己生成三个随机串：

```bash
openssl rand -hex 16   # 跑三次
```

分发：
- `REGISTER_SECRET` → 填进 iOS App 设置页
- `UPDATE_SECRET` → 填进 Mac agent 的环境变量
- `COMMAND_SECRET` → **同时**填进 iOS App 和 Mac agent

### 6. 部署

```bash
npm run deploy
```

部署成功会打印一个 URL，类似 `https://claude-traffic-light-relay.yourname.workers.dev`。**记下这个 URL，iOS App 和 Mac hook 都要用。**

## 验证

```bash
# 健康检查
curl https://YOUR-WORKER.workers.dev/health

# 模拟推送（在 iOS App 注册之前会返回 pushed: 0，是正常的）
curl -X POST https://YOUR-WORKER.workers.dev/update \
  -H "Content-Type: application/json" \
  -d '{"state":"R","secret":"你的-UPDATE_SECRET"}'
```

## 本地调试

```bash
cp .dev.vars.example .dev.vars
# 编辑 .dev.vars 填入真实值
npm run dev
```

监听日志：

```bash
npm run tail
```

## 接口

| 方法 | 路径 | 调用方 | Body / Query | 说明 |
|---|---|---|---|---|
| `POST` | `/register` | iOS App | `{token, secret}` | 用 `REGISTER_SECRET`，上传 Live Activity push token |
| `POST` | `/update` | Mac agent | `{state, secret, quota?, pending?}` | 用 `UPDATE_SECRET`，state 是 `R`/`Y`/`G`，可带配额和待批准操作 |
| `POST` | `/command` | iOS App | `{id, action, secret}` | 用 `COMMAND_SECRET`，action 是 `approve`/`deny` |
| `GET` | `/commands?secret=...` | Mac agent | — | 用 `COMMAND_SECRET`，返回并清空命令队列 |
| `GET` | `/health` | 任意 | — | 诊断 |

## 切到 production APNs

App 走 TestFlight / App Store 安装后，push token 类型变了，要把 `APNS_ENV` 改成 `production` 并重新部署：

```bash
# 编辑 wrangler.toml: APNS_ENV = "production"
npm run deploy
```

Xcode 直接装的 debug 版用 `development`，不要混。

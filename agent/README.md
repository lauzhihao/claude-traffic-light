# Mac Agent

驻留在「插着灯的那台 Mac」上的常驻进程，整个系统的仲裁核心：聚合所有机器、所有会话的状态 → 点灯 + 推手机。

## 它做什么

| 职责 | 触发 | 频率 |
|---|---|---|
| 接收 hook 事件（R/Y/G/PRE/PING/START/END） | `:7321/event` POST（本机 + tailnet 白名单机器） | 实时 |
| 多会话聚合，优先级 **🟡Y > 🔴R > 🟢G**，写 USB 串口 | 事件到达 / 周期兜底 | 实时 + 每 3s 强制重发 |
| 剔除崩溃/中断的会话 | 超时（全量 600s；R 无心跳 60s 降级 G） | 每 3s |
| iOS Live Activity 推送（APNs 直推，见 `apns.py`） | 状态变化 + 周期重推 | 实时 + 每 600s |
| 接收 iPhone 注册 Live Activity push token | `/register` POST（secret 把门） | App 打开时 |
| 计算 5h / 近 N 天 token 用量（N 默认 3，`CLAUDE_LIGHT_QUOTA_SCAN_DAYS` 可调） | 扫 `~/.claude/projects/**/*.jsonl`（仅 mtime 在窗口内的文件；仅启用推送时才扫） | 每 30s |
| 状态查询 / 排障 | `/health` GET | 按需 |

核心纯 stdlib；仅 iOS 推送需要 `agent/.venv`（`httpx[http2]` + `cryptography`），未配好时推送自动空转、纯本地灯不受影响。

> 历史note：早期版本经 Cloudflare Worker 中继推 APNs、并支持 tmux 注入实现手机远程批准。两者均已退役：APNs 改为 agent 本地直推（少一跳出境网络）；远程批准是**有意不做**的产品决策（只做状态灯，不复刻官方 App 的批准流）。

## 快速跑起来

### 一键安装（推荐）

```bash
bash agent/install.sh
```

自动生成并加载 launchd 服务（开机自启）、把 hooks 合并进 `~/.claude/settings.json`（先备份、幂等）。多机同步 / 客户端模式见根 [README](../README.md#多机同步tailscale)。

### 前台调试

```bash
python3 agent/agent.py
```

应该看到：

```
[agent] listening on 127.0.0.1:7321
[agent] serial glob: /dev/cu.usbmodem*
[agent] apns push: enabled (development, 1 tokens)
[agent] priority: Y > R > G   stale cutoff: 600s
```

打开新终端测试：

```bash
# 模拟一个 R 事件
curl -X POST http://127.0.0.1:7321/event \
  -H "Content-Type: application/json" \
  -d '{"state":"R","hook":{"session_id":"test"}}'

# 看 agent 状态（聚合值、各会话、白名单、APNs 状态）
curl -s http://127.0.0.1:7321/health
```

灯应变红；配好 APNs 的话 iPhone 灵动岛同步变色。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CLAUDE_LIGHT_BIND` | `127.0.0.1` | 多机同步设 `0.0.0.0` 监听 tailnet |
| `CLAUDE_LIGHT_AGENT_PORT` | `7321` | 监听端口 |
| `CLAUDE_LIGHT_SERIAL` | `/dev/cu.usbmodem*` | 串口 glob |
| `CLAUDE_LIGHT_SESSION_STALE_S` | `600` | 会话无事件多久剔除 |
| `CLAUDE_LIGHT_R_STALE_S` | `60` | R 无心跳多久降级 G（兜 ESC 中断） |
| `CLAUDE_LIGHT_PUSH_REFRESH_S` | `600` | APNs 周期重推间隔 |
| `CLAUDE_LIGHT_QUOTA_SCAN_DAYS` | `3` | 配额扫描窗口（天） |
| `CLAUDE_PROJECTS_DIR` | `~/.claude/projects` | 配额扫描目录 |
| `CLAUDE_LIGHT_REGISTER_SECRET` | 空 | `/register` 的密钥（空 = 拒绝注册） |
| `CLAUDE_LIGHT_CONFIG` | `~/.config/claude-traffic-light/config.json` | master/slaves 白名单 |
| `CLAUDE_LIGHT_APNS_P8` / `_KEY_ID` / `_TEAM_ID` / `_BUNDLE_ID` / `_ENV` | 空 / `development` | APNs 直推凭据，见 `apns.py` |

环境变量写进 `~/Library/LaunchAgents/com.claudelight.agent.plist`（`install.sh` 会生成），改完 `launchctl unload/load` 重启生效。

## 安全模型

- `/event`：只收本机（127/::1）+ 白名单（`config.json` 的 master/slaves）；没配白名单回退收整个 tailnet（100.64.0.0/10）。
- `/register`：额外放行家庭私网段（手机不装 Tailscale 也能注册），靠 `REGISTER_SECRET` 把门。
- `/health`：只读，同样放行私网段。

## 配额数据从哪来

直接解析 `~/.claude/projects/**/*.jsonl`：

- 每行一次 message 事件，取 `message.usage.{input,output,cache_read_input,cache_creation_input}_tokens` 求和
- 按 `timestamp` 过滤 5h / 近 N 天两个窗口（N 默认 3；下发 iOS 的键名保持 `tokens7d` 不变，免发版）
- 只读 mtime 在窗口内的文件，控制每 30s 一轮的 IO

Anthropic 没公开 quota API，所以这是**本地估算**，不是官方剩余配额。和 `ccusage` 同源逻辑，够当参考。

## 故障排查

| 现象 | 检查 |
|---|---|
| 灯不动 | `curl -s localhost:7321/health` 看 agent 在不在；`tail -f /tmp/claude-light-agent.log` |
| 远程机器状态到不了 | `/health` 的 `peers` 字段确认白名单；远程机器 hooks 是否装在跑 Claude 的那个用户下 |
| 灵动岛没反应 | `/health` 的 `apns` 字段看 enabled/reason/tokens；App 重开一次重新注册 |
| 推送 BadDeviceToken | `CLAUDE_LIGHT_APNS_ENV` 选错：Xcode debug 装的 → `development`，TestFlight/AppStore → `production` |
| Quota 一直是 0 | `ls ~/.claude/projects/` 确认目录存在；APNs 未启用时本来就不扫 |

# Mac Agent

驻留在 Mac 上的常驻进程。整个 T1（配额显示）+ T2（远程批准）的核心。

## 它做什么

| 职责 | 触发 | 频率 |
|---|---|---|
| 接收 hook 事件（R/Y/G/PRE） | localhost:7321/event POST | 实时 |
| 计算 5h / 7d token 用量 | 扫 `~/.claude/projects/**/conversation_*.jsonl` | 每 30s |
| 推送状态 + 配额 + 待批准操作到中继 | hook 触发后 | 实时 |
| 轮询中继命令队列 | GET /commands | 每 1s |
| 把 iOS 命令通过 tmux 注入 Claude | tmux send-keys | 命令到达时 |
| 写状态字节到 USB 串口（顺手）| open() 写 | hook 触发时 |

零外部 Python 依赖（纯 stdlib），不用装 pip 包。

## 快速跑起来

### 1. 装 tmux（如果还没有）

```bash
brew install tmux
```

### 2. 设环境变量

加到 `~/.zshrc`：

```bash
export CLAUDE_LIGHT_RELAY_URL="https://your-worker.workers.dev"
export CLAUDE_LIGHT_UPDATE_SECRET="部署 Worker 时 put 的 UPDATE_SECRET"
export CLAUDE_LIGHT_COMMAND_SECRET="部署 Worker 时 put 的 COMMAND_SECRET"
# 可选
export CLAUDE_LIGHT_TMUX_TARGET="claude"       # tmux session 名
export CLAUDE_LIGHT_AGENT_PORT="7321"          # 监听端口
export CLAUDE_LIGHT_SERIAL="/dev/tty.usbmodem*" # 硬件串口
```

```bash
source ~/.zshrc
```

### 3. 跑 agent（前台调试）

```bash
python3 agent/agent.py
```

应该看到：

```
[agent] listening on 127.0.0.1:7321
[agent] relay: https://your-worker.workers.dev
[agent] tmux target: claude
[agent] initial quota: 5h=123,456  7d=1,234,567
```

打开新终端测试：

```bash
# 模拟一个 R 事件
curl -X POST http://127.0.0.1:7321/event \
  -H "Content-Type: application/json" \
  -d '{"state":"R","hook":{}}'

# 看 agent 状态
curl http://127.0.0.1:7321/health
```

iPhone 上应该看到灵动岛变红。

### 4. 永久跑（开机自启）

复制 plist 模板：

```bash
cp agent/com.claudelight.agent.plist ~/Library/LaunchAgents/
```

编辑 `~/Library/LaunchAgents/com.claudelight.agent.plist`，把：
- `ABSOLUTE_PATH_TO_REPO` 换成本仓库真实路径
- 三个 secret 和 Worker URL 填进去

加载：

```bash
launchctl unload ~/Library/LaunchAgents/com.claudelight.agent.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.claudelight.agent.plist
```

看日志：

```bash
tail -f /tmp/claude-light-agent.log
```

### 5. 用 tmux 启 Claude（T2 必须）

T2 远程批准要求 Claude 必须跑在 `tmux` 会话里：

```bash
agent/claude-tmux.sh   # 自动创建/附着名为 "claude" 的 tmux session
```

之后任何时候都可以在新终端 `tmux attach -t claude` 接回去。

## 配额数据从哪来

直接解析 `~/.claude/projects/<project>/conversation_*.jsonl`：
- 每行是一次 message 事件
- 取 `message.usage.{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens}` 求和
- 按 `timestamp` 字段过滤 5h / 7d 窗口

Anthropic 没公开 quota API，所以这是**本地估算**，不是官方剩余配额。但和 `ccusage` 工具同源逻辑，足够当参考。

## 命令注入工作原理

iOS 灵动岛上的"批准/拒绝"按钮点击后：
1. iOS App 的 LiveActivityIntent 触发，POST 到中继 `/command` `{id, action}`
2. agent 每秒轮询中继 `/commands`，拉到命令
3. 校验 `id` 还是当前的 pending（防止过期命令）
4. `tmux send-keys -t claude y Enter`（或 `n Enter`）

Claude Code 的工具批准 TUI 接受：
- `y` 或 `1` = 允许一次
- `n` 或 `3` 或 `Esc` = 拒绝

如果你的 Claude 版本 hotkey 不同，改 `agent.py` 里 `execute_command()` 函数。

## 安全提醒

agent 只监听 `127.0.0.1`（localhost），外部网络访问不到。但仍要注意：
- 不要在共享 Mac 上跑（同机其他用户能 POST 到 localhost:7321 触发状态变化）
- 三个 SECRET 一定要随机，别用弱口令
- 当前没有命令白名单 / Face ID gate，所以**任何拿到你 iPhone 的人都能批准/拒绝 Claude 工具调用**。建议给 iPhone 设强解锁。

## 故障排查

| 现象 | 检查 |
|---|---|
| 灵动岛没反应 | `curl localhost:7321/health` 看 agent 是否在跑；`curl $RELAY_URL/health` 看中继配置 |
| Quota 一直是 0 | `ls ~/.claude/projects/` 确认目录存在；用 `CLAUDE_PROJECTS_DIR` 环境变量覆盖路径 |
| 批准/拒绝按 iOS 没反应 | `tmux ls` 确认有 "claude" session；agent 日志看是否拉到了命令 |
| `tmux send-keys` 报错 no session | 你没在 tmux 里跑 Claude，先 `claude-tmux.sh` |

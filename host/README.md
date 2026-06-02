# Mac/Linux Hook 脚本

把 Claude Code 的状态变化分发出去。**优先 POST 到本机 agent**（带完整 hook 上下文）；agent 不在时降级到"直推中继 + 写串口"的简单模式。

## 两种部署模式

| 模式 | 需要 | 拿到的功能 |
|---|---|---|
| **完整模式**（推荐）| Mac 上跑 `agent/agent.py` | 状态切换 + 配额显示 + 灵动岛按钮遥控 Claude |
| **极简模式** | 只用本脚本 + 中继 | 状态切换（红/黄/绿），无配额、无遥控 |

完整模式见 `../agent/README.md`。极简模式继续看下面。

## 极简模式安装

### 1. 设环境变量

把这几行加到 `~/.zshrc`（macOS 默认）或 `~/.bashrc`：

```bash
export CLAUDE_LIGHT_RELAY_URL="https://claude-traffic-light-relay.yourname.workers.dev"
export CLAUDE_LIGHT_UPDATE_SECRET="你 wrangler secret put 时填的 UPDATE_SECRET"

# 串口路径可选，默认 macOS 自动找 /dev/tty.usbmodem*
# Linux 改成 /dev/ttyACM0
# export CLAUDE_LIGHT_SERIAL="/dev/ttyACM0"
```

加完 `source ~/.zshrc` 生效。

### 2. 测试脚本

```bash
./light.sh R   # 灵动岛应该变红
./light.sh Y   # 变黄
./light.sh G   # 变绿
```

如果中继配置正确、iPhone 上点了"开始同步"，每次执行后 1 秒内灵动岛会响应。硬件没接上不会报错，会自动跳过。

### 3. 接到 Claude Code

编辑 `~/.claude/settings.json`，参考 `settings.snippet.json` 的 hooks 段。**记得把 `/ABSOLUTE/PATH/TO/` 换成 `light.sh` 的真实路径**：

```bash
# 拿到绝对路径
realpath ./light.sh
```

如果你已经有其它 hook，把 `UserPromptSubmit` / `Notification` / `Stop` 三段 merge 进去就行（同事件下数组里追加一项）。

### 4. 验证

随便跑一次 `claude` 对话，观察灵动岛 / 硬件灯：

| 时刻 | 应该看到 |
|---|---|
| 你按回车提交问题 | 🔴 红 |
| Claude 弹出工具调用确认 | 🟡 黄 |
| Claude 回答完毕、光标重新空闲 | 🟢 绿 |

## 行为说明

- 中继推送在**后台 subshell** 跑，即使网络慢也不会拖慢 Claude
- 串口写入是**同步**的，但只是写 1 个字节到本地 USB，耗时 < 5ms
- 任一目标不存在/失败都静默跳过，hook 永远返回 0
- 不传或传错状态值时直接 exit 0，不影响 Claude

## 调试

看 Claude Code 是否真的触发了 hook：

```bash
# 在 light.sh 顶部加一行临时日志
echo "$(date) $STATE" >> /tmp/claude-light.log
```

看中继有没有收到：

```bash
cd ../relay && npm run tail
```

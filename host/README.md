# Mac/Linux Hook 脚本

把 Claude Code 的状态变化分发出去。**优先 POST 到本机/指定机器的 agent**（带完整 hook 上下文）；agent 不在时降级为**直接写串口**（灯仍随本地状态切换，无多会话聚合、无 iOS 推送）。

## 两种部署模式

| 模式 | 需要 | 拿到的功能 |
|---|---|---|
| **完整模式**（推荐）| 插灯的 Mac 上跑 `agent/agent.py` | 多会话/多机聚合 + iOS 灵动岛推送 + 配额 |
| **极简模式** | 只用本脚本 + USB 灯 | 单机状态切换（红/黄/绿） |

完整模式见 `../agent/README.md`（一般直接 `bash agent/install.sh` 一键装好）。极简模式继续看下面。

## 极简模式安装

### 1. 设环境变量（可选）

```bash
# 串口路径可选，默认 macOS 自动找 /dev/tty.usbmodem*
# Linux 改成 /dev/ttyACM0
# export CLAUDE_LIGHT_SERIAL="/dev/ttyACM0"
```

### 2. 测试脚本

```bash
./light.sh R   # 灯变红
./light.sh Y   # 变黄
./light.sh G   # 变绿
```

硬件没接上不会报错，会自动跳过。

### 3. 接到 Claude Code

编辑 `~/.claude/settings.json`，参考 `settings.snippet.json` 的 hooks 段。**记得把 `/ABSOLUTE/PATH/TO/` 换成 `light.sh` 的真实路径**：

```bash
# 拿到绝对路径
realpath ./light.sh
```

如果你已经有其它 hook，把 `UserPromptSubmit` / `Notification` / `Stop` 三段 merge 进去就行（同事件下数组里追加一项）。

### 4. 验证

随便跑一次 `claude` 对话，观察硬件灯：

| 时刻 | 应该看到 |
|---|---|
| 你按回车提交问题 | 🔴 红 |
| Claude 弹出工具调用确认 | 🟡 黄 |
| Claude 回答完毕、光标重新空闲 | 🟢 绿 |

## 行为说明

- POST 到 agent 设了 2s 超时（`--noproxy '*'`），agent 不在也不会拖慢 Claude
- 串口写入是**同步**的，但只是写 1 个字节到本地 USB，耗时 < 5ms
- 任一目标不存在/失败都静默跳过，hook 永远返回 0
- 不传或传错状态值时直接 exit 0，不影响 Claude

## 调试

看 Claude Code 是否真的触发了 hook：

```bash
# 在 light.sh 顶部加一行临时日志
echo "$(date) $STATE" >> /tmp/claude-light.log
```

看 agent 有没有收到：

```bash
curl -s localhost:7321/health   # sessions 字段应出现你的会话
```

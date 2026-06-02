# Claude 红绿灯 🚦

一个迷你 USB 红绿灯硬件，实时显示 Claude Code 的状态：

| 灯色 | 含义 | 触发时机 |
|---|---|---|
| 🔴 红 | Claude 正在推理 | `UserPromptSubmit` hook |
| 🟡 黄 | 等待你的决策（批准工具调用 / 输入） | `Notification` hook |
| 🟢 绿 | 推理完成，可以看结果了 | `Stop` hook |

**用途**：当你让 Claude 跑长任务、切去刷别的窗口时，用余光扫一眼桌面就知道它什么状态——不用再切回终端反复确认。

**参赛**：抖音 Vibe Coding 作品大赛。

## 架构

```
Claude (tmux) ──hook──> light.sh ──> Mac Agent ──┬─> USB ──> Pico ──> 红绿灯
                                          ↑       ├─> Worker ──APNs──> iPhone 灵动岛
                                          │       │                   + Apple Watch
                                          │       │                   + 锁屏批准按钮
                       ccusage 扫 jsonl ──┘       │
                                                  │
                            tmux send-keys ◄──────┘ (轮询命令)
                                                  ▲
                                                  │
                            iOS 灵动岛"批准/拒绝"按钮 → AppIntent → Worker
```

Mac Agent 是核心调度器：算配额、发推送、收命令、注入 tmux。详见 [IOS.md](./IOS.md) 和 [agent/README.md](./agent/README.md)。

## 目录

```
claude-traffic-light/
├── README.md           # 本文件
├── TODO.md             # 待办 / 里程碑
├── HARDWARE.md         # 淘宝采购清单 + 接线图
├── IOS.md              # iOS App + 灵动岛 + 云中继架构
├── firmware/           # Pico 端 MicroPython 代码
├── host/               # Claude Code hook 脚本（极简模式）
├── agent/              # Mac 常驻 agent：配额 + 双向命令通道
├── ios/                # iOS App + Widget Extension + AppIntents
└── relay/              # Cloudflare Worker 中继代码（双向）
```

## 硬件成本

约 ¥60–110（含 3D 打印外壳）。详见 [HARDWARE.md](./HARDWARE.md)。

## 本地部署 / 移植到新机器（无 iOS）

只要桌面这盏灯 + 一台 Mac 就能跑（灵动岛/云中继是可选的 iOS 增强）。**搬到新机器三步**：

1. **硬件**：固件在 Pico 板子里、与电脑无关——换机器直接把红绿灯的 USB 插到新机器即可。首次烧录见 [firmware/README.md](./firmware/README.md)。
2. **软件**：克隆本仓库，跑一键脚本：
   ```bash
   bash agent/install.sh
   ```
   它自动：生成并加载 launchd 服务（开机自启 `agent.py`）、把 3 个 hook 合并进 `~/.claude/settings.json`（先备份、幂等、不动你已有配置）。
3. 插上 USB，在 Claude Code 里随便聊一句，灯就动。

**原理**：Claude Code 的 hook（提交→R / 通知→Y / 结束→G）→ `host/light.sh` → 本机 `agent.py`（:7321）。agent 按 `session_id` 聚合**所有并发会话**，按 **🟡等你 > 🔴推理 > 🟢完成 > ⚫️无** 点灯。详见 [agent/README.md](./agent/README.md)。

排查：`curl -s localhost:7321/health`、`tail -f /tmp/claude-light-agent.log`。

## 当前进度

见 [TODO.md](./TODO.md)。

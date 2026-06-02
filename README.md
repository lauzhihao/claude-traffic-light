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

## 当前进度

见 [TODO.md](./TODO.md)。

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

## 多机同步（Tailscale）

让多台机器（本地 + 远程）的 Claude 状态汇到同一盏灯，靠 Tailscale 点对点直连，**不需要中转服务器**。

- **插灯那台（服务端）** — 让 agent 监听 tailnet：
  ```bash
  CLAUDE_LIGHT_BIND=0.0.0.0 bash agent/install.sh
  ```
  查它的 tailscale IP：`tailscale ip -4`（当前插灯的是 macbook-pro = `100.119.112.116`）。

- **新增/迁移到一台机器，让它的状态上报到灯（客户端）** — 在那台机器 `git clone` 本仓库后，跑这条（IP 换成插灯那台的 tailscale IP）：
  ```bash
  CLAUDE_LIGHT_AGENT_HOST=100.119.112.116 bash agent/install.sh
  ```
  👉 **这就是迁移到新 tailnet 机器时要跑的那条命令。** 它只配 hooks（状态经 Tailscale 发给插灯那台），不起 agent、不碰串口。装完会**自测**（发个临时会话到目标 agent 再查 `/health`），当场告诉你状态能不能到灯——一次抓出 IP 错 / 端口错 / 没连同一 tailnet / agent 没跑。

  - **换了插灯机（灯机 IP 变了）？** 每台客户端都要把 `CLAUDE_LIGHT_AGENT_HOST` 换成新 IP 重跑本命令。重跑会**就地把旧 IP 改成新 IP**（逐事件幂等、不重复加、不动你其它 hook），不必手改 `settings.json`。
  - **⚠ 装错用户会静默丢状态：** hooks 写进的是「跑 `install.sh` 那个用户」的 `~/.claude/settings.json`。要是你的 Claude Code 实际跑在别的用户下（远程机常见 root），就得用**那个用户**重跑本命令，否则 hooks 进了错文件、状态发不出去且全程不报错。

agent 把每台的会话分别纳入聚合，按 **🟡等你 > 🔴推理 > 🟢完成 > ⚫️无** 点灯（含 `AskUserQuestion` 提问→黄、CLAUDE.md「等 Go 授权」→黄）。

## 本地优先：Tailscale 只是「边缘路径」，不阻塞主流程

灯的主流程是 **本地 Claude → `127.0.0.1:7321` 的 agent → USB 串口 → 灯**，走环回（loopback），**完全不经过 Tailscale**。因此：

- 插灯的机器**即使不在 Tailscale 上、或 Tailscale 断了**，本地 Claude Code / app 的状态**照样实时切灯**。
- Tailscale 只负责把**其它机器**的状态捎过来（边缘路径）；它断开只是暂时看不到远程机器，本地灯一切照常。

这由三层保障，都不依赖 Tailscale：
1. **本地 hook 发往 `127.0.0.1`**——`CLAUDE_LIGHT_AGENT_HOST` 不设时默认就是它（插灯那台务必用**服务端模式**安装，即不带 `AGENT_HOST`）；
2. **agent 绑 `0.0.0.0`**，没有 Tailscale 也能正常监听本地；
3. agent 万一没在跑，`light.sh` 会**直接写串口兜底**（降级，但灯仍随本地状态切换）。

> 想完全独立用（不联网、不接 Tailscale）：插灯那台直接 `bash agent/install.sh`（默认只监听本地 `127.0.0.1`）即可，无需任何 Tailscale 配置。

## 当前进度

见 [TODO.md](./TODO.md)。

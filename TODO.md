# TODO / 里程碑

> 状态标记：`[ ]` 未开始 · `[~]` 进行中 · `[x]` 完成 · `[!]` 阻塞 · `[$]` 等账号 · `[📦]` 等硬件

---

## 🎉 本地版已跑通（2026-06-02 · 无 iOS）

硬件到货焊好 + 接入 Claude Code，**多会话状态灯已在日常使用**：

- [x] Pico 烧 MicroPython + `firmware/main.py`（USB-C RP2040 克隆板）
- [x] 接线点亮：VCC→**3V3**（非 5V，否则数据电平喂不进）、共地、GP15 菊花链；物理顺序 红1/黄2/绿3
- [x] 串口实时控制 R/Y/G/0 + 红呼吸/黄慢闪/绿常亮/开机自检（已调亮）
- [x] `agent.py` 重写为**多会话聚合仲裁者**：按 `session_id` 取最高优先级 **Y>R>G** 写串口，崩溃会话超时剔除
- [x] 全局 hooks 接入 → 一盏灯反映**所有并发会话**（🟡等你 > 🔴推理 > 🟢完成 > ⚫️无）
- [x] launchd 开机自启（`~/Library/LaunchAgents/com.claudelight.agent.plist`）
- [x] 一键部署脚本 `agent/install.sh`（移植新机器：clone → 跑脚本 → 插 USB）

> iOS / 灵动岛 / 配额 / 云中继（Phase A–C、H）按需求**暂缓**；`agent.py` 里相关代码保留，未配环境变量时自动空转。

---

## ✅ 已就绪（T1+T2 全部代码已写完）

- [x] 项目骨架 + 文档（README / HARDWARE / IOS / TODO）
- [x] Pico 固件：`firmware/main.py`（3 灯 + 呼吸/慢闪/常亮动画 + 开机自检）
- [x] Hook 分发器：`host/light.sh`（优先 agent，fallback 中继+串口）
- [x] Hook 配置模板：`host/settings.snippet.json`（含 PreToolUse）
- [x] Cloudflare Worker 中继：`relay/src/index.js`
  - `/register` 收 iOS push token
  - `/update` 收 agent 状态/配额/待批准操作
  - `/command` 收 iOS 命令、`/commands` 给 agent 拉
  - JWT 签名 + 死 token 自动清理
- [x] Mac Agent：`agent/agent.py`（纯 stdlib，零依赖）
  - localhost:7321 收 hook 事件
  - 扫 `~/.claude/projects/*.jsonl` 算 5h/7d token 用量
  - 轮询中继命令队列、tmux send-keys 注入 Claude
  - 写 USB 串口（顺手）
- [x] tmux 包装：`agent/claude-tmux.sh`（T2 必须在 tmux 里跑 Claude）
- [x] launchd 模板：`agent/com.claudelight.agent.plist`（开机自启）
- [x] iOS App 全部 Swift 源码：
  - `ClaudeAttributes.swift` 数据结构（state + quota + pending）
  - `AppIntents.swift` ApproveIntent / DenyIntent（灵动岛按钮触发）
  - `ContentView.swift` 主 App（3 个 secret 配置 + 启动按钮）
  - `ClaudeLiveActivity.swift` 灵动岛 4 视图 + 锁屏视图 + 配额条 + 批准按钮

下一次开机时只要 Apple 账号到位 + 硬件到货，**填变量 + 跑命令**就能整套点亮。

---

## Phase A — Apple Developer 账号 🍎  `[$]`

- [ ] 注册 Apple Developer Program（$99/年，审核约 24-48h）
- [ ] 创建 Bundle ID（如 `com.yourname.claudetrafficlight`）
- [ ] 生成 APNs Authentication Key（`.p8` 文件，**只能下载一次**，存好）
- [ ] 记下三个字符串：**Team ID**、**Key ID**、**Bundle ID**

## Phase B — 部署 Cloudflare Worker 中继 ☁️

> 详见 `relay/README.md`

- [ ] `cd relay && npm install`
- [ ] `npx wrangler login`
- [ ] `npx wrangler kv:namespace create STORE`，把 id 填进 `wrangler.toml`
- [ ] 改 `wrangler.toml` 里的 `APNS_BUNDLE_ID`
- [ ] `wrangler secret put` 注入 **6 个** secret（APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID / REGISTER_SECRET / UPDATE_SECRET / COMMAND_SECRET）
- [ ] `npm run deploy`，记下 Worker URL
- [ ] `curl /health` 验证

## Phase C — 装 iOS App 到真机 📱

> 详见 `ios/README.md`

- [ ] Xcode 新建 App 项目（Bundle ID 必须和 Phase A 创建的一致）
- [ ] 加 Widget Extension target（勾 "Include Live Activity"）
- [ ] 把 `ios/` 下 **6 个 Swift 文件**拖进对应 target（`ClaudeAttributes.swift` 和 `AppIntents.swift` 都要勾两个 target）
- [ ] Info.plist 加 `NSSupportsLiveActivities = YES`
- [ ] 启用 Push Notifications capability
- [ ] USB 接 iPhone，⌘R 装到真机
- [ ] App 里填 Worker URL + REGISTER_SECRET + COMMAND_SECRET，点"开始同步"
- [ ] 手动 curl 中继 `/update` → 灵动岛变色（验证 T1）

## Phase D — 部署 Mac Agent 🤖

> 详见 `agent/README.md`

- [ ] `brew install tmux`
- [ ] `~/.zshrc` 加 4 个环境变量（RELAY_URL / UPDATE_SECRET / COMMAND_SECRET / TMUX_TARGET）
- [ ] 前台跑 `python3 agent/agent.py`，确认日志输出和 `curl localhost:7321/health` OK
- [ ] 配 launchd plist 让 agent 开机自启
- [ ] Hook 配置：把 `settings.snippet.json` 4 段（含 PreToolUse）合并进 `~/.claude/settings.json`
- [ ] 用 `agent/claude-tmux.sh` 启动 Claude（必须在 tmux 里跑）
- [ ] 测试 T1：随便聊几句，灵动岛上配额数字开始增长
- [ ] 测试 T2：让 Claude 调一个需要批准的 Bash 命令 → 锁屏 iPhone → 在锁屏上点"批准" → 桌面 Claude 接到命令继续 ✨
- [ ] **🎉 T1+T2 完整跑通**

---

## Phase E — 硬件采购 🛒  `[📦]`

- [ ] 下单：Pico H × 1
- [ ] 下单：WS2812 单灯模块（已焊线版）× 3
- [ ] 下单：杜邦线母对母一包
- [ ] 下单：Micro-USB 数据线（家里有就不买）
- [ ] 下单：面包板 170 孔（可选但强烈推荐）

## Phase F — 烧录 Pico ⚡

- [ ] Pico 上电，板载绿灯亮起
- [ ] BOOTSEL + 插 USB → 拖 MicroPython UF2 进 RPI-RP2 盘
- [ ] Thonny 打开 `firmware/main.py` → 另存为 Pico 上的 `main.py`
- [ ] 拔插 USB，验证开机自检红黄绿闪一次

## Phase G — 接线 & 联调

- [ ] 按 HARDWARE.md 接 3 颗 WS2812 到 GP15 + 3V3 + GND（菊花链）
- [ ] `echo -n R > /dev/tty.usbmodem*` 手测灯切换
- [ ] 跑一次 Claude 对话：硬件灯 + 灵动岛 + Apple Watch 表盘**三屏同步**变色
- [ ] 边界测试：网络断开时灯仍然正常；Apple Watch 抬腕显示正确

## Phase H — Apple Watch 优化（可选）⌚

- [ ] iOS 18+ 给 Live Activity 加 `supplementalActivityFamilies([.small])`
- [ ] 用 `@Environment(\.activityFamily)` 分支渲染 `.small` 紧凑视图
- [ ] 可选：写 WidgetKit Complication，让用户钉到表盘

## Phase I — 外壳组装 🏗️

- [ ] 量准 Pico + 接线后整体尺寸
- [ ] 下单 3D 打印迷你红绿灯外壳
- [ ] 双面胶/热熔胶固定 Pico 和 3 颗灯
- [ ] 测试组装后 USB 线插拔
- [ ] 整理走线，封后盖

## Phase J — 参赛交付 🎬

- [ ] 录制 demo 视频，至少包含：
  - [ ] 桌面镜头：红绿灯实物 + 显示器上的 Claude Code 同框
  - [ ] **三屏同步镜头**：手机灵动岛 + Apple Watch 表盘 + 桌面红绿灯同时变色
  - [ ] **配额镜头**：聊几轮，灵动岛上 5h/7d token 数字实时跳动
  - [ ] **遥控镜头**（最炸）：跑长任务 → 离开座位 → Claude 弹出工具批准 → **在路上掏出 iPhone 锁屏直接点"批准"** → Claude 继续干活
  - [ ] "它救了我"真实场景
- [ ] 项目文档整理（README / HARDWARE / IOS / 接线图 / 完整代码）
- [ ] 仓库推 GitHub
- [ ] 按抖音参赛要求剪视频、配文案、发布

---

## 想到再加 💭

- [ ] 蓝牙版（无线放置更灵活，成本翻倍）
- [ ] 多种模式：除了红绿灯，做成进度条 / 心率灯 / 等等
- [ ] 灯端做成 USB HID 设备，免驱动
- [ ] 出一个"作品复刻包"，让其他 Claude Code 用户买齐料自拼
- [ ] Android Wear 支持（需要 FCM + Android 手机 App + Wear OS App，成本高）

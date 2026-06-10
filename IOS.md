# iOS 灵动岛同步架构

## 为什么需要这么多组件

iOS 不允许任何第三方（蓝牙/WiFi/任何本地协议）直接刷新灵动岛，**只接受 Apple 官方推送服务（APNs）**。所以最终的数据通路必须是：

```
你的 Mac (Claude hook → agent.py 聚合)
    │
    │ agent 内置 apns.py：HTTP/2 + JWT(ES256) 鉴权
    ▼
Apple APNs 服务器
    │
    │ 推送 (apns-push-type: liveactivity)
    ▼
iPhone 上你写的那个 iOS App
    │
    │ 系统自动转发
    ▼
灵动岛动画刷新 🔴/🟡/🟢
```

整链路延迟实测一般 < 1 秒，对"红黄绿状态"够用。

> 早期版本在 Mac 和 APNs 之间隔了一层 Cloudflare Worker 中继，已于 2026-06 退役：签 JWT 推 Apple 这件事本地完全能做（`agent/apns.py`），少一跳出境网络（workers.dev 在国内必须走代理，APNs 反而直连可达），也少一套要维护的云端密钥。

## 三个组件分别要做什么

### 1. iOS App（Swift / SwiftUI）

**作用**：注册一个 Live Activity，把 Apple 颁发的推送 Token 上传给 Mac 上的 agent。

App 打开即自动同步（无需手填）：
- `ActivityKit` 启动一个 `Activity<ClaudeAttributes>`
- 拿到 `pushToken`（一个只对这个 activity 有效的 token）
- POST 给 agent 的 `/register`：`{ token: "...", secret: "<你设的密钥>" }`（家庭 Wi-Fi 走 `.local` Bonjour 名，装了 Tailscale 走 100.x，按 `RelayConfig.urls` 顺序尝试）

灵动岛 UI 在 **Widget Extension** 里写（同一个 Xcode project 的另一个 target）：

| 视图 | 内容 |
|---|---|
| Compact Leading | 一个状态色小圆点 🔴/🟡/🟢 |
| Compact Trailing | 文字 "thinking" / "waiting" / "ready" |
| Expanded | 大圆点 + 完整状态文本 + 上次更新时间 |
| Minimal | 一个 SF Symbol（如 `circle.fill` 上色） |
| 锁屏横幅 | 红绿灯造型 + 状态文本 |

**坑提醒**：
- Live Activity 必须 **iOS 16.1+**
- **必须真机测试**，Simulator 对 Live Activity 支持不完整
- 单个 Activity 最多活 8 小时，到期前要重启（Claude 会话一般远短于 8 小时，问题不大）
- App 第一次启动要请求 Live Activity 权限（用户在系统设置里也能关）

### Apple Watch（顺手送的特性）

**iOS 17 + watchOS 10 起，Live Activity 自动同步到 Apple Watch 的 Smart Stack**，不需要写独立的 watchOS App。只要 iPhone 那边灵动岛跑通，戴 Apple Watch 抬腕就能看到。

要让手表上显示得更好看，加一行：

```swift
.supplementalActivityFamilies(.small)
```

给 Live Activity 定义一套手表专属布局（表盘小，需要更紧凑的设计，比如只显示一个大色块圆点 + 单词 "Claude"）。

可选加分项：写一个 **Complication**（表盘上的永久小部件），用 WidgetKit。用户把它钉到表盘后，即便没有正在运行的 Live Activity 也能看到最近一次的颜色。

### 2. 本地 APNs 直推（`agent/apns.py`，内置在 agent 里）

**作用**：状态变化时把聚合结果转成 APNs 推送格式 → 直接推给 Apple。

它要做的事：
1. `POST /register`：iOS App 把 push token 注册进来（agent 持久化到本地文件，重启不丢）
2. 状态变化 / 周期重推：给每个已注册 token 发 APNs 推送（失败重试 + 600s 周期兜底，防止手机错过推送永久停在旧颜色）
3. APNs 推送用 ES256 算法签 JWT（用你的 `.p8` Auth Key），HTTP/2 直连 `api.push.apple.com`

依赖 `agent/.venv`（`httpx[http2]` + `cryptography`）；APNs 凭据经 `CLAUDE_LIGHT_APNS_*` 环境变量注入，未配齐时推送自动空转、桌面灯照常。

APNs 推送的 payload 长这样：
```json
{
  "aps": {
    "timestamp": 1735000000,
    "event": "update",
    "content-state": { "state": "R" }
  }
}
```

请求头：
```
apns-push-type: liveactivity
apns-topic: <你的 Bundle ID>.push-type.liveactivity
apns-priority: 10
authorization: bearer <JWT>
```

### 3. Apple Developer 配置（一次性）

- 注册 [Apple Developer Program](https://developer.apple.com/programs/)（$99/年）
- 在 Certificates, Identifiers & Profiles 里创建：
  - **App ID / Bundle ID**：比如 `com.yourname.claudetrafficlight`
  - **APNs Authentication Key**（`.p8` 文件，下载后只能下一次，存好）
  - 记下：**Team ID**、**Key ID**、Bundle ID 三个字符串
- Xcode 里启用 `Push Notifications` capability

## 开发顺序建议

```
1. Apple Dev 账号 + 创建 Bundle ID + .p8 key      （半天，主要是等审核）
2. 手动调一次 APNs，确认 .p8 + JWT 正确            （1 小时）
3. agent 配好 CLAUDE_LIGHT_APNS_* 环境变量         （30 分钟）
4. Xcode 建 App + Widget Extension                （半天）
5. 真机测 Live Activity 启动 + 接收推送            （1 天，含调坑）
```

预计总投入：**1-2 个周末**。

## 与硬件的关系

iOS 推送和硬件串口是**并行**两条路，agent 聚合后同时分发：

```
Claude hook (R) → agent.py 聚合
    ├── 写串口 /dev/cu.usbmodem...       （硬件红绿灯亮红）
    └── apns.py 直推 Apple               （灵动岛变红）
```

这意味着任何一边坏了另一边都不受影响。视频拍摄时两边同步亮起的效果非常加分。

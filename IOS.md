# iOS 灵动岛同步架构

## 为什么需要这么多组件

iOS 不允许任何第三方（蓝牙/WiFi/任何本地协议）直接刷新灵动岛，**只接受 Apple 官方推送服务（APNs）**。所以最终的数据通路必须是：

```
你的 Mac (Claude hook)
    │
    │ HTTPS POST
    ▼
云端中继 (Cloudflare Worker)
    │
    │ HTTP/2 + JWT 鉴权
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

## 三个组件分别要做什么

### 1. iOS App（Swift / SwiftUI）

**作用**：注册一个 Live Activity，把 Apple 颁发的推送 Token 上传到你的中继。

最小 UI 只有一个按钮："开始同步 Claude"。点了之后：
- `ActivityKit` 启动一个 `Activity<ClaudeAttributes>`
- 拿到 `pushToken`（一个只对这个 activity 有效的 token）
- POST 给中继：`{ token: "...", secret: "<你设的密钥>" }`

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

### 2. 云中继（Cloudflare Worker 推荐）

**作用**：接 Mac 的 webhook → 转成 APNs 推送格式 → 推给 Apple。

为什么选 Cloudflare Worker：
- 免费额度对个人项目绰绰有余（每天 10 万次请求）
- 自带 HTTPS 域名，省事
- 自带 KV 存储，存推送 token
- 边缘部署，延迟低
- 唯一的"麻烦"是要写 JavaScript，但代码量不到 100 行

它要做的事：
1. `POST /register`：iOS App 把 push token 存到 KV
2. `POST /update`：Mac hook 来调用，参数 `{state: "R"}` → 取出 KV 里所有 token → 给每个 token 发 APNs 推送
3. APNs 推送需要用 ES256 算法签 JWT（用你的 `.p8` Auth Key）

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
2. 用 Postman 手动调一次 APNs，确认 .p8 + JWT 正确 （1 小时）
3. 写 Worker 中继，本地用 wrangler dev 跑          （半天）
4. Xcode 建 App + Widget Extension                （半天）
5. 真机测 Live Activity 启动 + 接收推送            （1 天，含调坑）
6. 把 Mac hook 改成同时推串口 + 推中继              （30 分钟）
```

预计总投入：**1-2 个周末**。

## 与硬件的关系

iOS 推送和硬件串口是**并行**两条路，hook 同时触发：

```
Claude hook (R)
    ├── echo R > /dev/tty.usbmodem...    （硬件红绿灯亮红）
    └── curl POST relay/update           （灵动岛变红）
```

这意味着任何一边坏了另一边都不受影响。视频拍摄时两边同步亮起的效果非常加分。

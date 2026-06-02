# iOS App · ClaudeTrafficLight

Live Activity 把 Claude 状态显示到灵动岛、锁屏、Apple Watch Smart Stack。

## 文件清单

```
ios/
├── ClaudeTrafficLight/                     # 主 App target
│   ├── ClaudeTrafficLightApp.swift         # App 入口
│   ├── ContentView.swift                   # 主 UI（中继配置 + 启动按钮）
│   └── ClaudeAttributes.swift              # ⚠️ 加入两个 target 的 Membership
└── ClaudeTrafficLightWidget/               # Widget Extension target
    ├── ClaudeTrafficLightWidgetBundle.swift
    └── ClaudeLiveActivity.swift            # 灵动岛四种视图 + 锁屏视图
```

## 一次性 Xcode 设置（约 10 分钟）

> 前提：Apple Developer 账号已激活，Xcode 15+ 已装，准备好一台 iOS 17+ 真机（Simulator 对 Live Activity 支持不全）。

### 1. 新建 Xcode 项目

- File → New → Project → **iOS** → **App**
- Product Name: `ClaudeTrafficLight`
- Interface: **SwiftUI**
- Language: **Swift**
- Bundle ID: 必须和 Apple Developer 后台创建的 Bundle ID **一致**（如 `com.yourname.claudetrafficlight`）
- Team: 选你的开发者账号

### 2. 加 Widget Extension target

- File → New → Target → **Widget Extension**
- Product Name: `ClaudeTrafficLightWidget`
- ✅ 勾选 **Include Live Activity**（关键！）
- Activate scheme 提示选 **Cancel**（继续用主 App scheme）

### 3. 替换源文件

把 Xcode 自动生成的 .swift 文件**全部删掉**，把本目录下的文件按结构拖进去：

| 文件 | 拖到 Xcode 哪个 group | Target Membership |
|---|---|---|
| `ClaudeTrafficLightApp.swift` | ClaudeTrafficLight | ✅ ClaudeTrafficLight |
| `ContentView.swift` | ClaudeTrafficLight | ✅ ClaudeTrafficLight |
| `ClaudeAttributes.swift` | ClaudeTrafficLight | ✅ **两个都勾** |
| `AppIntents.swift` | ClaudeTrafficLight | ✅ **两个都勾** |
| `ClaudeTrafficLightWidgetBundle.swift` | ClaudeTrafficLightWidget | ✅ ClaudeTrafficLightWidget |
| `ClaudeLiveActivity.swift` | ClaudeTrafficLightWidget | ✅ ClaudeTrafficLightWidget |

> `ClaudeAttributes.swift` 和 `AppIntents.swift` 必须被两个 target 共享，否则编译过不去。在 File Inspector 右侧栏勾选两个 target。

### 4. 主 App 启用 Live Activity

打开主 App 的 `Info.plist`（或 Build Settings → Custom iOS Target Properties），加一条：

| Key | Type | Value |
|---|---|---|
| `NSSupportsLiveActivities` | Boolean | `YES` |

### 5. 启用 Push Notifications capability

选中主 App target → Signing & Capabilities → `+ Capability` → **Push Notifications**。

> 不需要写 `application:didRegisterForRemoteNotificationsWithDeviceToken:` 那一套老代码。Live Activity 的 push token 是从 `Activity.pushTokenUpdates` 这个 async sequence 拿的，已经写在 `ContentView.swift` 里了。

### 6. 编译 & 装到真机

- 用 USB 接 iPhone，Xcode 选这台真机为目标
- ⌘R 运行
- 第一次会问"信任开发者证书"，去 iPhone 设置 → 通用 → VPN与设备管理 → 信任

## 运行

1. App 启动后，填入三个字段：
   - **Worker URL**：你部署的 Cloudflare Worker 地址，如 `https://claude-traffic-light-relay.yourname.workers.dev`
   - **REGISTER_SECRET**：和 Worker 那边 `wrangler secret put REGISTER_SECRET` 设的同一个字符串
   - **COMMAND_SECRET**：和 Worker 那边 `wrangler secret put COMMAND_SECRET` 设的同一个字符串（不填的话灵动岛上的"批准/拒绝"按钮按了不会有效果）
2. 点"开始同步"
3. 状态变成 "已注册到中继 ✓" 后，把手机锁屏或滑到主屏幕——灵动岛会显示一个绿色小圆点（初始状态）
4. 在 Mac 上跑 `host/light.sh R`（或触发任意 Claude hook），灵动岛立刻变红

## Live Activity 视图布局

灵动岛 / 锁屏会显示这些信息：

| 区域 | 内容 |
|---|---|
| Compact Leading | 状态色小圆点 |
| Compact Trailing | thinking / waiting / ready 文字 |
| Expanded Leading | 大状态色圆点带发光 |
| Expanded Center | "Claude Code" + 状态文字 |
| Expanded Trailing | 三灯竖排小图（红绿灯造型） |
| Expanded Bottom | **黄灯时**：显示工具名 + 预览 + 批准/拒绝按钮；**其他状态**：显示 5h / 7d 配额 |
| 锁屏 | 大三灯造型 + 状态文字 + 配额；黄灯时叠加批准按钮 |

## Apple Watch

iOS 17 + watchOS 10 起，Live Activity 自动同步到 Apple Watch Smart Stack，**不需要额外代码**。

如果想给 Watch 单独定制更紧凑的布局（iOS 18+），在 `ClaudeLiveActivity.swift` 的 `ActivityConfiguration` 后面加：

```swift
.supplementalActivityFamilies([.small])
```

然后在 widget 内分支判断 `@Environment(\.activityFamily)`，给 `.small` 渲染一个更简单的版本（如只有一个状态色圆点）。当前代码没加，因为基础布局在 Watch 上已经能看，作品交付后再优化。

## 常见问题

**Q: 编译报错 "Cannot find ClaudeAttributes in scope"**
A: `ClaudeAttributes.swift` 没勾上 Widget target 的 Membership。

**Q: 灵动岛不出现**
A:
- 检查 `NSSupportsLiveActivities = YES`
- 检查设置 → ClaudeTrafficLight → "实时活动"是否开启
- 真机系统必须 iOS 16.1+，灵动岛硬件必须 iPhone 14 Pro 及以上
- 没有灵动岛硬件的 iPhone 不会显示岛，但锁屏 banner 仍然会出现

**Q: push token 一直没拿到**
A: 检查 Signing & Capabilities 里 **Push Notifications** 是否启用，以及 Apple Dev 后台 Bundle ID 是否启用了 Push 服务。

**Q: 中继收到推送但 APNs 返回 BadDeviceToken**
A: 多半是 `APNS_ENV` 选错了。Xcode debug 装的 App → `development`；TestFlight/AppStore → `production`。

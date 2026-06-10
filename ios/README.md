# iOS App · ClaudeTrafficLight

Live Activity 把 Claude 状态显示到灵动岛、锁屏、Apple Watch Smart Stack。

## 文件清单

```
ios/
├── ClaudeTrafficLight/                     # 主 App target
│   ├── ClaudeTrafficLightApp.swift         # App 入口（强制浅色主题）
│   ├── ContentView.swift                   # 主 UI：左上角状态单灯 + 状态词（开屏自动同步，无需手填）
│   ├── RelayConfig.example.swift           # agent 地址/密钥模板——复制为 RelayConfig.swift 填值(真文件已 gitignore)
│   ├── AppIntents.swift                    # ⚠️ 批准/拒绝 Intent（死代码，见下），加入两个 target 的 Membership
│   ├── ClaudeAttributes.swift              # ⚠️ 加入两个 target 的 Membership
│   └── Factory/                            # 内容工厂卡片墙（首页灯下方的 agent 任务收件箱）
│       ├── AgentHome.swift                 #   6 个 agent 卡片 + 状态灯 + 服务器设置
│       ├── NofClient.swift / NofModels.swift  # ncds-opus-studio 后端 LAN 客户端（契约见该仓库 FRONTEND-API.md）
│       └── …任务列表/详情/产物视图等
└── ClaudeTrafficLightWidget/               # Widget Extension target
    ├── ClaudeTrafficLightWidgetBundle.swift
    ├── ClaudeLiveActivity.swift            # 灵动岛四种视图 + 锁屏视图
    └── StatusIconWidget.swift              # 主屏 systemSmall Widget（底图 + 动态状态圆点）
```

> 本目录是真机工程（`~/Documents/ClaudeTrafficLight`，独立 git 仓库）的源码快照,只收 Swift 文件;Assets / Info.plist / entitlements 等 Xcode 工程文件不入快照。`RelayConfig.swift` 含真实地址/密钥,已被 `.gitignore`(同步快照时可照常复制,git 不会收)——仓库只放脱敏模板 `RelayConfig.example.swift`。`Factory/` 是同一个 App 里的另一条产品线(ncds 内容工厂前端),与红绿灯功能无耦合,但 `ContentView` 嵌入了它的 `AgentBoard`,快照若不带它将无法编译。

> Mac agent 的地址（`.local` Bonjour 名 + Tailscale IP）和密钥编译期写死在 `RelayConfig.swift` 里，App 装上即用、**不用在界面里填任何配置**。该文件含真实密钥、已被 `.gitignore`——首次构建前 `cp RelayConfig.example.swift RelayConfig.swift` 填入自己的值；换机器或轮换密钥时也只改它再重新编译。推送本身由 Apple APNs 下发（agent 直推），这些地址只用于「注册 token」和「开屏读一次状态」。

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

先生成自己的连接配置（模板里有每个字段的说明）：

```bash
cp ClaudeTrafficLight/RelayConfig.example.swift ClaudeTrafficLight/RelayConfig.swift
# 编辑 RelayConfig.swift:填你 Mac 的 .local 地址和 CLAUDE_LIGHT_REGISTER_SECRET
```

然后把 Xcode 自动生成的 .swift 文件**全部删掉**，把本目录下的文件按结构拖进去（**不要拖 `RelayConfig.example.swift`**，否则 enum 重名编译报错）：

| 文件 | 拖到 Xcode 哪个 group | Target Membership |
|---|---|---|
| `ClaudeTrafficLightApp.swift` | ClaudeTrafficLight | ✅ ClaudeTrafficLight |
| `ContentView.swift` | ClaudeTrafficLight | ✅ ClaudeTrafficLight |
| `Factory/` 整个目录 | ClaudeTrafficLight | ✅ ClaudeTrafficLight |
| `RelayConfig.swift` | ClaudeTrafficLight | ✅ **两个都勾** |
| `ClaudeAttributes.swift` | ClaudeTrafficLight | ✅ **两个都勾** |
| `AppIntents.swift` | ClaudeTrafficLight | ✅ **两个都勾** |
| `ClaudeTrafficLightWidgetBundle.swift` | ClaudeTrafficLightWidget | ✅ ClaudeTrafficLightWidget |
| `ClaudeLiveActivity.swift` | ClaudeTrafficLightWidget | ✅ ClaudeTrafficLightWidget |
| `StatusIconWidget.swift` | ClaudeTrafficLightWidget | ✅ ClaudeTrafficLightWidget |

> `RelayConfig.swift`、`ClaudeAttributes.swift`、`AppIntents.swift` 必须被两个 target 共享，否则编译过不去。在 File Inspector 右侧栏勾选两个 target。

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

配置已写死在 `RelayConfig.swift`，**App 打开即自动同步，无需任何手填**：

1. 装上后第一次启动，系统会弹「是否允许实时活动」——点允许（之后也能在 设置 → ClaudeTrafficLight → 实时活动 里开关）。
2. App 会自动启动一个 Live Activity 并把 push token 注册到 Mac agent（`/register`）；首页左上角显示**实时状态单灯 + 状态词**（下方是内容工厂的 agent 卡片墙），状态行出现 "已同步" 即成功。
3. 把手机锁屏或滑到主屏——灵动岛/锁屏会出现红绿灯（初始绿）。
4. 在 Mac 上触发任意 Claude 推理（或手动 `host/light.sh R`），灵动岛和 App 单灯立刻切到 **Thinking（琥珀呼吸）**。

> ⚠️ 状态字节 ≠ 颜色：点亮逻辑对齐实物灯固件——**R(推理)=琥珀、Y(等待决策)=红、G(空闲)=绿**。看到 R 别期待红色。

> 万一主屏显示 "请在设置打开实时活动"，去 设置 → ClaudeTrafficLight 打开后重开 App；或点界面上的「重新连接」。

## Live Activity 视图布局

灵动岛 / 锁屏会显示这些信息（状态色 = 实物灯色：R 琥珀 / Y 红 / G 绿）：

| 区域 | 内容 |
|---|---|
| Compact Leading | 状态色小圆点 |
| Compact Trailing | Thinking / Asking / Idle 文字（状态色） |
| Expanded Leading | 玻璃质感大灯泡 |
| Expanded Center | "Claude" + 状态词 |
| Expanded Trailing | 三灯竖排小红绿灯 |
| Expanded Bottom | 5h / 近3天 token 配额 |
| 锁屏 | 横版三灯胶囊（样式对齐 App 首页）+ 右上角状态色胶囊 |

> Live Activity 由系统快照渲染，**跑不了呼吸/循环动画**——只有主 App 里能做黄灯呼吸、文字波浪；灵动岛/锁屏是静态点亮态。

> 代码里残留的 `pending` / 批准按钮分支是早期远程批准方案的死代码——agent 永远不下发 `pending`，按钮不会出现。远程批准已确定不做（定位 = 状态灯）。

## Apple Watch

iOS 17 + watchOS 10 起，Live Activity 自动同步到 Apple Watch Smart Stack，**不需要额外代码**。

如果想给 Watch 单独定制更紧凑的布局（iOS 18+），在 `ClaudeLiveActivity.swift` 的 `ActivityConfiguration` 后面加：

```swift
.supplementalActivityFamilies([.small])
```

然后在 widget 内分支判断 `@Environment(\.activityFamily)`，给 `.small` 渲染一个更简单的版本（如只有一个状态色圆点）。当前代码没加，因为基础布局在 Watch 上已经能看，作品交付后再优化。

## App 图标 + 主屏 Widget

`icon/` 下是图标资源和生成器:

- `gen.py` → 用 SVG 程序化生成图标(`icon.svg`),`rsvg-convert` 渲染、ImageMagick 去 alpha。
- `AppIcon-1024.png`:暖珊瑚径向底 + 奶油色**有机不对称星芒**(Claude 风格**原创**,且整体水平镜像以区别于原标),**无圆点**,居中。装进主 App 的 `Assets.xcassets/AppIcon.appiconset`(单张 1024 通用)。
- `IconBase-1024.png`:与 App 图标**同一张**,装进 Widget 的 `Assets.xcassets/IconBase.imageset` 当背景;Widget 在它上面叠一个**动态状态圆点**(那是组件功能,图标本身不带点)。

**主屏 Widget**(`ClaudeTrafficLightWidget/StatusIconWidget.swift`,已加进 `WidgetBundle`):`systemSmall`,底图 + SwiftUI 动态圆点(R/Y/G),数据由 Widget 自己定时拉 agent `/health` 的 `latest.state`。

### 两条 iOS 现实约束(重要)

1. **第三方做不了「时钟那种」实时动图标**——那是 Apple 私有权限。App 图标只能是静态 PNG;`setAlternateIconName` 能在预置图标间切换,但每次切都弹系统提示、且只在前台,不适合频繁的推理状态。所以:
   - **真·实时状态** → 灵动岛/锁屏的 **Live Activity**(本来就有)。
   - **主屏图标式存在感** → 本 Widget,但 iOS 给 Widget 的刷新有**每日配额**,是「准实时」,可能滞后几分钟。
2. **商标**:自用(Xcode 装自己手机)用 Claude 真图标没事;**上架/公开 TestFlight 用 Anthropic 真 logo 会被 App Review 拒、也算侵权**。所以这里用的是 Claude *风格*原创图标,可安全分享。

## 常见问题

**Q: 编译报错 "Cannot find ClaudeAttributes / RelayConfig / ApproveIntent in scope"**
A: 对应的 `ClaudeAttributes.swift` / `RelayConfig.swift` / `AppIntents.swift` 没勾上 Widget target 的 Membership（这三个文件两个 target 都要勾）。报 RelayConfig 时还有一种可能：忘了先 `cp RelayConfig.example.swift RelayConfig.swift`。

**Q: 灵动岛不出现**
A:
- 检查 `NSSupportsLiveActivities = YES`
- 检查设置 → ClaudeTrafficLight → "实时活动"是否开启
- 真机系统必须 iOS 16.1+，灵动岛硬件必须 iPhone 14 Pro 及以上
- 没有灵动岛硬件的 iPhone 不会显示岛，但锁屏 banner 仍然会出现

**Q: push token 一直没拿到**
A: 检查 Signing & Capabilities 里 **Push Notifications** 是否启用，以及 Apple Dev 后台 Bundle ID 是否启用了 Push 服务。

**Q: agent 推送时 APNs 返回 BadDeviceToken**
A: 多半是 `CLAUDE_LIGHT_APNS_ENV` 选错了。Xcode debug 装的 App → `development`；TestFlight/AppStore → `production`。

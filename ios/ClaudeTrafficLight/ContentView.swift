import SwiftUI
import ActivityKit

// 配色:主色调 Claude 土黄,强调色橙
extension Color {
    static let ctTan     = Color(red: 0.91, green: 0.85, blue: 0.74)  // 土黄背景
    static let ctInk     = Color(red: 0.26, green: 0.19, blue: 0.13)  // 深棕文字
    static let ctOrange  = Color(red: 0.85, green: 0.45, blue: 0.18)  // 橙色强调/按钮
    static let ctHousing = Color(red: 0.16, green: 0.13, blue: 0.11)  // 灯壳深色
    static let ctAmber   = Color(red: 1.00, green: 0.50, blue: 0.00)  // 推理=黄(琥珀)呼吸,匹配固件 AMBER
    static let ctCard    = Color(red: 0.97, green: 0.94, blue: 0.88)  // 暖象牙卡片面,浮在土黄底上
}

// 配置已写死在 RelayConfig,App 打开即自动同步。
// 首页:顶部横版红绿灯 + 状态词;中部留白(待接入业务工作流)。
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var activity: Activity<ClaudeAttributes>?
    @State private var state: String = "G"
    @State private var status: String = ""
    @State private var didSync = false
    @State private var booting = true   // 自检中:主灯红黄绿闪烁,完成后显真实状态
    @State private var lastToken: String?   // 最近一次拿到的推送 token,前台补注册用
    @State private var registered = false   // 最近一次注册是否成功

    var body: some View {
        NavigationStack {
            ZStack {
                Color.ctTan.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        // 英雄区:左上角单灯(与下方头像左缘对齐) + 右侧状态词
                        HStack(spacing: 12) {
                            MainStatusLight(state: state, loading: booting)

                            HStack(spacing: 6) {
                                Text("Claude").foregroundStyle(Color.ctInk)
                                if booting {
                                    Text("Connecting").foregroundStyle(Color.ctInk.opacity(0.45))
                                } else {
                                    WaveText(
                                        text: stateWordLocal(state),
                                        color: stateColorLocal(state),
                                        animated: state == "R" || state == "Y",
                                        period: state == "Y" ? 1.0 : 1.6   // Asking 更急促,Thinking 平稳
                                    )
                                }
                            }
                            .font(CTType.serif(24, bold: true))   // Fraunces 接管灯状态文案,与灵动岛/锁屏一致

                            Spacer()
                        }
                        .padding(.leading, 14)   // 灯左缘对齐下方 agent 头像左缘
                        .padding(.top, 4)

                        if !status.isEmpty && !booting {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(Color.ctInk.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 14)
                        }

                        // 单灯下方:智能体卡片墙
                        AgentBoard()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .foregroundStyle(Color.ctInk)
                }

                // 剪贴板捕获:复制了抖音等平台分享链接进 App,弹卡问要不要交给沈括
                ClipboardCaptureLayer()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if !didSync { await bootstrap(); return }
            // 回到前台:补一次灯态;注册上次没成功就重试——
            // 后台/锁屏时 token 轮换触发的注册常被系统掐断,不能让错误一直挂着
            await fetchLatest()
            if !registered, let token = lastToken { await register(token: token) }
        }
    }

    // MARK: - 同步逻辑

    @MainActor
    func bootstrap() async {
        await fetchLatest()
        if let existing = Activity<ClaudeAttributes>.activities.first {
            if activity == nil {
                activity = existing
                withAnimation { state = existing.content.state.state }
                observe(existing)
            }
            didSync = true
        } else {
            await start()
        }
        booting = false   // 自检结束:主灯停止 RYG 闪烁,显真实状态
    }

    @MainActor
    func start() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "Enable Live Activities in Settings → ClaudeTrafficLight, then reopen the app"
            return
        }
        let initial = ClaudeAttributes.ContentState(state: state, updatedAt: .now)
        for attempt in 1...6 {
            do {
                let act = try Activity.request(
                    attributes: ClaudeAttributes(name: "Claude Code"),
                    content: .init(state: initial, staleDate: nil),
                    pushType: .token
                )
                activity = act
                didSync = true
                status = ""
                observe(act)
                return
            } catch {
                status = "Starting… (\(attempt)/6)"
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        status = "连接失败,重开 App 重试"
    }

    func observe(_ act: Activity<ClaudeAttributes>) {
        Task {
            for await tokenData in act.pushTokenUpdates {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                await register(token: token)
            }
        }
        Task {
            for await content in act.contentUpdates {
                await MainActor.run { withAnimation { state = content.state.state } }
            }
        }
    }

    // 把本机 Live Activity push token 注册到中继(POST /v1/register,Bearer 鉴权)。
    func register(token: String) async {
        await MainActor.run { lastToken = token }
        var notes: [String] = []
        for base in RelayConfig.urls {
            guard let url = URL(string: "\(base)/v1/register") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(RelayConfig.apiToken)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["deviceToken": token])
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    await MainActor.run { registered = true; status = "" }
                    return
                }
                notes.append("HTTP \(code)")
            } catch {
                notes.append(error.localizedDescription)
            }
        }
        let detail = notes.joined(separator: " · ")
        await MainActor.run { registered = false; status = "Registration failed — \(detail)" }
    }

    // best-effort:从中继读一次当前状态(GET /v1/state,Bearer),失败就静默。
    func fetchLatest() async {
        for base in RelayConfig.urls {
            guard let url = URL(string: "\(base)/v1/state") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            req.setValue("Bearer \(RelayConfig.apiToken)", forHTTPHeaderField: "Authorization")
            guard
                let (data, _) = try? await URLSession.shared.data(for: req),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let s = obj["state"] as? String
            else { continue }
            await MainActor.run { withAnimation { state = s } }
            return
        }
    }
}

// MARK: - 主状态灯(单灯版,置左上)

/// 单灯版主状态灯。语义不变(同固件/横版三灯):
/// 空闲 G=绿常亮 / 推理 R=黄呼吸 / 等待 Y=红闪。
/// loading=true 时红黄绿循环闪烁,代替"自检 loading"。
struct MainStatusLight: View {
    let state: String
    var loading: Bool
    var diameter: CGFloat = 30

    var body: some View {
        if loading {
            // 自检中:红→黄→绿 硬切循环闪烁
            TimelineView(.animation) { tl in
                let idx = Int(tl.date.timeIntervalSinceReferenceDate / 0.45) % 3
                let colors: [Color] = [.red, .ctAmber, .green]
                TrafficBulb(color: colors[idx], isOn: true, motion: .solid,
                            period: 1, dimTo: 1, diameter: diameter)
            }
        } else {
            TrafficBulb(color: stateColor, isOn: true, motion: stateMotion,
                        period: statePeriod, dimTo: stateDim, diameter: diameter)
        }
    }

    private var stateColor: Color { state == "Y" ? .red : state == "R" ? .ctAmber : .green }
    private var stateMotion: BulbMotion { state == "R" ? .breathe : state == "Y" ? .blink : .solid }
    private var statePeriod: Double { state == "Y" ? 0.7 : state == "R" ? 3.0 : 1.0 }
    private var stateDim: Double { state == "R" ? 0.45 : 1.0 }
}

// MARK: - 单灯泡:呼吸 / 闪烁 / 常亮 + 玻璃灯罩质感

/// 灯泡动效,与固件三种动画一一对应:
/// `.breathe` 推理=黄呼吸,`.blink` 等待=红闪,`.solid` 空闲=绿常亮。
enum BulbMotion { case breathe, blink, solid }

/// 一颗红绿灯灯泡。点亮时按 `motion` 决定动效:
/// 用 `TimelineView(.animation)` 驱动——呼吸是正弦平滑起伏,闪烁是方波硬切;
/// 常亮/熄灭时时间线自动暂停(省电,也避免静态灯泡多余重绘)。
struct TrafficBulb: View {
    let color: Color
    let isOn: Bool
    let motion: BulbMotion
    let period: Double      // 呼吸/闪烁的周期秒数(越小越急促)
    let dimTo: Double       // 呼吸最暗时的亮度(0~1,越小起伏越明显);闪烁/常亮不用
    var diameter: CGFloat = 56

    private let blinkDuty: Double = 0.6   // 闪烁亮态占比,和固件一致

    var body: some View {
        // 常亮无需逐帧;只有呼吸/闪烁且点亮时才驱动 TimelineView。
        let animating = isOn && motion != .solid
        TimelineView(.animation(paused: !animating)) { timeline in
            bulb(level: level(at: timeline.date))
                // 仅在亮/灭切换时做淡入淡出;动效帧不受这条动画影响。
                .animation(.easeInOut(duration: 0.3), value: isOn)
        }
    }

    /// 当前亮度:熄灭=0,常亮=1,呼吸=dimTo~1 正弦,闪烁=0/1 方波。
    private func level(at date: Date) -> Double {
        guard isOn else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        switch motion {
        case .solid:
            return 1
        case .breathe:
            let s = (sin(2 * .pi * t / period) + 1) / 2     // 0~1
            return dimTo + (1 - dimTo) * s
        case .blink:
            let phase = (t / period).truncatingRemainder(dividingBy: 1)
            return phase < blinkDuty ? 1 : 0                // 方波快闪
        }
    }

    private func bulb(level: Double) -> some View {
        Circle()
            .fill(color.opacity(0.14 + 0.86 * level))    // 熄灭也留一点底色,像没通电的灯罩
            .overlay(
                // 左上角高光,做出玻璃灯罩的立体反光
                Circle().fill(
                    RadialGradient(
                        colors: [.white.opacity(0.55 * level), .clear],
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 0,
                        endRadius: diameter * 0.55
                    )
                )
            )
            .overlay(Circle().stroke(.white.opacity(0.05 + 0.28 * level), lineWidth: 1.5))
            .frame(width: diameter, height: diameter)
            .scaleEffect(0.95 + 0.06 * level)            // 呼吸时轻微胀缩,更像在「喘气」
            .shadow(color: color.opacity(0.9 * level), radius: diameter * 0.4 * level)
    }
}

// MARK: - 逐字母波浪文字

/// 把文字拆成单个字母,用一条从左向右滚动的正弦波依次把每个字母「顶起放大」,
/// 形成逐字母依次变大的波浪效果。`animated == false` 时静止平铺(用于 Idle)。
struct WaveText: View {
    let text: String
    let color: Color
    var animated: Bool
    var period: Double = 1.6        // 波浪滚过一轮的秒数(越小越急促)
    var amplitude: CGFloat = 0.45   // 放大幅度:波峰处字母放大到 1 + amplitude 倍
    var stagger: Double = 0.6       // 相邻字母的相位差(弧度,越大波越「陡」)

    var body: some View {
        TimelineView(.animation(paused: !animated)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(Array(text.enumerated()), id: \.offset) { index, ch in
                    // 每个字母相位错开,max(0, sin) 让字母多数时间正常、波峰短暂弹大
                    let phase = t / period * 2 * .pi - Double(index) * stagger
                    let lift = animated ? max(0, sin(phase)) : 0
                    Text(String(ch))
                        .scaleEffect(1 + amplitude * CGFloat(lift), anchor: .bottom)
                        .offset(y: -CGFloat(lift) * 3)   // 配合放大轻微上跳,更有弹性
                }
            }
            .foregroundStyle(color)
            .animation(.easeInOut(duration: 0.3), value: animated)
        }
    }
}

// 文案/灯色对齐实物灯:推理=黄(琥珀),等待=红,空闲=绿
func stateColorLocal(_ s: String) -> Color {
    switch s {
    case "R": return .ctAmber
    case "Y": return .red
    case "G": return .green
    default:  return .gray
    }
}

// 英文状态词,与灵动岛/锁屏保持一致
func stateWordLocal(_ s: String) -> String {
    switch s {
    case "R": return "Thinking"
    case "Y": return "Asking"
    case "G": return "Idle"
    default:  return "—"
    }
}

#Preview {
    ContentView()
}

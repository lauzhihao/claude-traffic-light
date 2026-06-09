import SwiftUI
import ActivityKit

// 配色:主色调 Claude 土黄,强调色橙
extension Color {
    static let ctTan     = Color(red: 0.91, green: 0.85, blue: 0.74)  // 土黄背景
    static let ctInk     = Color(red: 0.26, green: 0.19, blue: 0.13)  // 深棕文字
    static let ctOrange  = Color(red: 0.85, green: 0.45, blue: 0.18)  // 橙色强调/按钮
    static let ctHousing = Color(red: 0.16, green: 0.13, blue: 0.11)  // 灯壳深色
}

// 配置已写死在 RelayConfig,App 打开即自动同步。
// 首页:顶部横版红绿灯 + 状态词;中部留白(待接入业务工作流)。
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var activity: Activity<ClaudeAttributes>?
    @State private var state: String = "G"
    @State private var status: String = ""
    @State private var didSync = false

    var body: some View {
        ZStack {
            Color.ctTan.ignoresSafeArea()

            VStack(spacing: 16) {
                // 横版红绿灯:置顶居中
                HorizontalTrafficLight(state: state)
                    .padding(.top, 8)

                Text(stateLabelLocal(state))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(stateColorLocal(state))
                    .contentTransition(.opacity)

                if !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.ctInk.opacity(0.55))
                        .multilineTextAlignment(.center)
                }

                // 中部留白:后续接入专用业务工作流
                Spacer()

                if activity == nil {
                    Button {
                        Task { await start() }
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.ctOrange)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .foregroundStyle(.ctInk)
        }
        .task(id: scenePhase) {
            if scenePhase == .active && !didSync { await bootstrap() }
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
    }

    @MainActor
    func start() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "请在 设置 → ClaudeTrafficLight 打开「实时活动」后重开 App"
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
                status = "正在启动…(\(attempt)/6)"
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        status = "启动失败,请点下方「重新连接」"
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

    func register(token: String) async {
        guard let url = URL(string: "\(RelayConfig.url)/register") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token,
            "secret": RelayConfig.registerSecret,
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            await MainActor.run { status = code == 200 ? "" : "注册失败 HTTP \(code)" }
        } catch {
            await MainActor.run { status = "注册请求失败:\(error.localizedDescription)" }
        }
    }

    // best-effort:从中继 /health 读一次当前状态,失败就静默。
    func fetchLatest() async {
        guard let url = URL(string: "\(RelayConfig.url)/health") else { return }
        guard
            let (data, _) = try? await URLSession.shared.data(from: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let latest = obj["latest"] as? [String: Any],
            let s = latest["state"] as? String
        else { return }
        await MainActor.run { withAnimation { state = s } }
    }
}

// MARK: - 横版红绿灯(置顶)

struct HorizontalTrafficLight: View {
    let state: String

    var body: some View {
        HStack(spacing: 20) {
            bulb(.red,    on: state == "R")
            bulb(.yellow, on: state == "Y")
            bulb(.green,  on: state == "G")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(Color.ctHousing)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
    }

    func bulb(_ c: Color, on: Bool) -> some View {
        Circle()
            .fill(on ? c : c.opacity(0.15))
            .frame(width: 56, height: 56)
            .overlay(Circle().stroke(.white.opacity(on ? 0.28 : 0.06), lineWidth: 1.5))
            .shadow(color: on ? c.opacity(0.9) : .clear, radius: on ? 16 : 0)
            .animation(.easeInOut(duration: 0.25), value: on)
    }
}

func stateColorLocal(_ s: String) -> Color {
    switch s {
    case "R": return .red
    case "Y": return Color(red: 0.85, green: 0.6, blue: 0.0)
    case "G": return Color(red: 0.13, green: 0.55, blue: 0.23)
    default:  return .gray
    }
}

func stateLabelLocal(_ s: String) -> String {
    switch s {
    case "R": return "推理中 · thinking"
    case "Y": return "等你 · waiting"
    case "G": return "就绪 · ready"
    default:  return "—"
    }
}

#Preview {
    ContentView()
}

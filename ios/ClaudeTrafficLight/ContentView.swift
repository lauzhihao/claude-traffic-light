import SwiftUI
import ActivityKit

// 配置已写死在 RelayConfig,App 打开即自动同步——没有任何要填的字段。
struct ContentView: View {
    @State private var activity: Activity<ClaudeAttributes>?
    @State private var state: String = "G"
    @State private var status: String = "正在连接中继…"
    @State private var lastUpdate: Date?

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Text("Claude 红绿灯")
                .font(.largeTitle.bold())

            BigTrafficLight(state: state)

            Text(stateLabelLocal(state))
                .font(.title2.bold())
                .foregroundStyle(stateColorLocal(state))
                .contentTransition(.opacity)

            VStack(spacing: 4) {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let lastUpdate {
                    Text("更新于 \(lastUpdate.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if activity == nil {
                Button {
                    Task { await start() }
                } label: {
                    Label("重新连接", systemImage: "arrow.clockwise")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            }

            Text(RelayConfig.url.replacingOccurrences(of: "https://", with: ""))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .task { await bootstrap() }
    }

    // 开屏即自动同步:已有 Live Activity 就接管,没有就新建一个。
    @MainActor
    func bootstrap() async {
        await fetchLatest()   // 先从中继拿一次当前状态,App 一打开就显示对的颜色
        if let existing = Activity<ClaudeAttributes>.activities.first {
            activity = existing
            state = existing.content.state.state
            lastUpdate = existing.content.state.updatedAt
            status = "已同步 ✓ 灵动岛会自动更新"
            observe(existing)
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
        do {
            let initial = ClaudeAttributes.ContentState(state: state, updatedAt: .now)
            let act = try Activity.request(
                attributes: ClaudeAttributes(name: "Claude Code"),
                content: .init(state: initial, staleDate: nil),
                pushType: .token
            )
            activity = act
            status = "已启动,正在注册推送…"
            observe(act)
        } catch {
            status = "启动失败:\(error.localizedDescription)"
        }
    }

    // 同时监听:① push token(自动注册到中继)② 内容更新(刷新 App 里的灯)
    func observe(_ act: Activity<ClaudeAttributes>) {
        Task {
            for await tokenData in act.pushTokenUpdates {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                await register(token: token)
            }
        }
        Task {
            for await content in act.contentUpdates {
                await MainActor.run {
                    withAnimation { state = content.state.state }
                    lastUpdate = content.state.updatedAt
                }
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
            await MainActor.run {
                status = code == 200
                    ? "已同步 ✓ 灵动岛会自动更新"
                    : "注册失败 HTTP \(code)"
            }
        } catch {
            await MainActor.run { status = "注册请求失败:\(error.localizedDescription)" }
        }
    }

    // best-effort:从中继 /health 读一次当前状态,失败就静默(纯锦上添花)。
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

// MARK: - App 内的大红绿灯

struct BigTrafficLight: View {
    let state: String

    var body: some View {
        VStack(spacing: 18) {
            bulb(.red, on: state == "R")
            bulb(.yellow, on: state == "Y")
            bulb(.green, on: state == "G")
        }
        .padding(26)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    func bulb(_ c: Color, on: Bool) -> some View {
        Circle()
            .fill(on ? c : c.opacity(0.14))
            .frame(width: 76, height: 76)
            .shadow(color: on ? c : .clear, radius: on ? 26 : 0)
            .animation(.easeInOut(duration: 0.25), value: on)
    }
}

func stateColorLocal(_ s: String) -> Color {
    switch s {
    case "R": return .red
    case "Y": return .yellow
    case "G": return .green
    default: return .gray
    }
}

func stateLabelLocal(_ s: String) -> String {
    switch s {
    case "R": return "thinking · 推理中"
    case "Y": return "waiting · 等你"
    case "G": return "ready · 就绪"
    default: return "—"
    }
}

#Preview {
    ContentView()
}

import SwiftUI
import ActivityKit

struct ContentView: View {
    @AppStorage("relayUrl") private var relayUrl: String = ""
    @AppStorage("registerSecret") private var registerSecret: String = ""
    @AppStorage("commandSecret") private var commandSecret: String = ""

    @State private var activity: Activity<ClaudeAttributes>?
    @State private var status: String = "未启动"
    @State private var lastToken: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("中继配置") {
                    TextField("Worker URL", text: $relayUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("REGISTER_SECRET", text: $registerSecret)
                    SecureField("COMMAND_SECRET（遥控批准/拒绝）", text: $commandSecret)
                }

                Section {
                    if activity == nil {
                        Button("开始同步") {
                            Task { await start() }
                        }
                        .disabled(relayUrl.isEmpty || registerSecret.isEmpty)
                    } else {
                        Button("停止同步", role: .destructive) {
                            Task { await stop() }
                        }
                    }
                }

                Section("说明") {
                    Text("REGISTER_SECRET 必填，用于把这台手机注册到中继。\nCOMMAND_SECRET 可选，配了之后灵动岛上的按钮才能遥控 Mac 上的 Claude 批准/拒绝工具。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("状态") {
                    Text(status).font(.callout)
                    if !lastToken.isEmpty {
                        Text("Token: \(lastToken)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Claude 红绿灯")
        }
    }

    @MainActor
    func start() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "请在设置 → ClaudeTrafficLight 里开启 Live Activity"
            return
        }
        do {
            let attrs = ClaudeAttributes(name: "Claude Code")
            let initial = ClaudeAttributes.ContentState(
                state: "G",
                updatedAt: .now
            )
            let act = try Activity.request(
                attributes: attrs,
                content: .init(state: initial, staleDate: nil),
                pushType: .token
            )
            activity = act
            status = "已启动，等待 push token…"
            Task { await observe(activity: act) }
        } catch {
            status = "启动失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    func stop() async {
        guard let act = activity else { return }
        await act.end(nil, dismissalPolicy: .immediate)
        activity = nil
        status = "已停止"
    }

    func observe(activity act: Activity<ClaudeAttributes>) async {
        for await tokenData in act.pushTokenUpdates {
            let token = tokenData.map { String(format: "%02x", $0) }.joined()
            await MainActor.run {
                lastToken = String(token.prefix(12)) + "…"
            }
            await register(token: token)
        }
    }

    func register(token: String) async {
        guard let url = URL(string: "\(relayUrl)/register") else {
            await MainActor.run { status = "Worker URL 不合法" }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token,
            "secret": registerSecret,
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            await MainActor.run {
                status = code == 200
                    ? "已注册到中继 ✓ 等 Mac 那边推状态"
                    : "注册失败 HTTP \(code)"
            }
        } catch {
            await MainActor.run { status = "注册请求失败：\(error.localizedDescription)" }
        }
    }
}

#Preview {
    ContentView()
}

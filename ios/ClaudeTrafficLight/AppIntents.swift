import AppIntents
import Foundation

// 灵动岛 / 锁屏 / Apple Watch 上"批准 / 拒绝"按钮触发的 Intent。
// 必须加入主 App 和 Widget Extension 两个 target 的 Membership。

public struct ApproveIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "批准"
    public static var description = IntentDescription("批准 Claude 的工具调用")

    @Parameter(title: "Request ID")
    public var requestId: String

    public init() { self.requestId = "" }
    public init(requestId: String) { self.requestId = requestId }

    public func perform() async throws -> some IntentResult {
        await RelayCommand.send(id: requestId, action: "approve")
        return .result()
    }
}

public struct DenyIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "拒绝"
    public static var description = IntentDescription("拒绝 Claude 的工具调用")

    @Parameter(title: "Request ID")
    public var requestId: String

    public init() { self.requestId = "" }
    public init(requestId: String) { self.requestId = requestId }

    public func perform() async throws -> some IntentResult {
        await RelayCommand.send(id: requestId, action: "deny")
        return .result()
    }
}

enum RelayCommand {
    static func send(id: String, action: String) async {
        let defaults = UserDefaults.standard
        guard
            let relayUrl = defaults.string(forKey: "relayUrl"),
            !relayUrl.isEmpty,
            let commandSecret = defaults.string(forKey: "commandSecret"),
            !commandSecret.isEmpty,
            let url = URL(string: "\(relayUrl)/command")
        else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id": id,
            "action": action,
            "secret": commandSecret,
        ])
        req.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: req)
    }
}

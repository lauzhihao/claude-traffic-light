import Foundation

// 写死的中继配置——不用在 App 里手填,装上即用。
//
// ⚠️ Xcode 里把本文件加入「两个 target」的 Membership(主 App + Widget Extension),
//    因为 AppIntents.swift(批准/拒绝按钮,两个 target 共享)也要读这里的值。
//
// 这些值会编进 App 二进制,属于「半公开」——对这种个人项目足够安全。
// 以后换中继 / 轮换密钥,只改这一处再重新编译即可。
enum RelayConfig {
    static let url = "https://claude-traffic-light-relay.claude-light.workers.dev"
    static let registerSecret = "ROTATED-2026-06-10"
    static let commandSecret = "ROTATED-2026-06-10"
}

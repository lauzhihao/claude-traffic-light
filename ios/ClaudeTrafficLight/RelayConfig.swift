import Foundation

// 写死的中继配置——不用在 App 里手填,装上即用。
//
// ⚠️ Xcode 里把本文件加入「两个 target」的 Membership(主 App + Widget Extension),
//    因为 AppIntents.swift(批准/拒绝按钮,两个 target 共享)也要读这里的值。
//
// 这些值会编进 App 二进制,属于「半公开」——对这种个人项目足够安全。
// 以后换中继 / 轮换密钥,只改这一处再重新编译即可。
//
// 中继已从 Cloudflare Worker 迁回 Mac 本机:agent(:7321)内置 APNs 直推。
// 注册按 urls 顺序逐个尝试:家庭 Wi-Fi 走 Bonjour 名(DHCP 换 IP 也稳,
// ATS 对 .local 豁免);手机若装了 Tailscale,第二个地址在任何网络可达
// (ATS 对裸 IP 同样豁免)。推送本身由 Apple 下发,与这些地址无关——
// 只有「注册 token」和「开屏读一次状态」需要够到 Mac。
enum RelayConfig {
    static let urls = [
        "http://liuzhihao-mbp.local:7321",
        "http://100.119.112.116:7321",
    ]
    static let url = urls[0]   // 旧引用(AppIntents)仍用单地址
    static let registerSecret = "ROTATED-2026-06-10"
    static let commandSecret = "ROTATED-2026-06-10"
}

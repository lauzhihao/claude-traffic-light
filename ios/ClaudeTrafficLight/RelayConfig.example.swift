import Foundation

// agent 连接配置模板——复制为 RelayConfig.swift 后填入你自己的值再编译:
//
//   cp RelayConfig.example.swift RelayConfig.swift
//
// RelayConfig.swift 含真实地址/密钥,已被 .gitignore,不会进仓库。
// ⚠️ Xcode 里只把 RelayConfig.swift 加入工程(勾主 App + Widget 两个 target),
//    本模板文件不要加,否则 enum 重名编译报错。
//
// urls 按顺序逐个尝试注册:第一个填 Mac 的 Bonjour 名(同一 Wi-Fi 可达,
// DHCP 换 IP 也稳,ATS 对 .local 豁免);手机装了 Tailscale 可再加一条
// tailscale IP 兜底(任何网络可达)。推送本身由 Apple APNs 下发,与这些
// 地址无关——只有「注册 token」和「开屏读一次状态」需要够到 Mac。
enum RelayConfig {
    static let urls = [
        "http://your-mac.local:7321",
        // "http://100.x.y.z:7321",   // 可选:插灯 Mac 的 Tailscale IP
    ]
    static let url = urls[0]   // 旧引用(AppIntents)仍用单地址

    // 与插灯 Mac 上的 CLAUDE_LIGHT_REGISTER_SECRET 一致(建议 openssl rand -hex 16)
    static let registerSecret = "REPLACE_WITH_REGISTER_SECRET"

    // 历史遗留:仅被远程批准死代码引用,该功能已砍,随便填
    static let commandSecret = "UNUSED"
}

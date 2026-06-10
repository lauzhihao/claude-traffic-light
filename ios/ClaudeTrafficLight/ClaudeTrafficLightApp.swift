import SwiftUI

@main
struct ClaudeTrafficLightApp: App {
    var body: some Scene {
        WindowGroup {
            // 整套设计是暖色浅色主题,强制 .light,避免系统暗色把输入框/表单变黑框
            ContentView().preferredColorScheme(.light)
        }
    }
}

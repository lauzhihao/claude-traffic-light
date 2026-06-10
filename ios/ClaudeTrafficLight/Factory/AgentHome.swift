import SwiftUI

// 首页红绿灯下方的「智能体卡片墙」。
// 全部用 SwiftUI 标准控件 + 复用现有 TrafficBulb（缩小版三连灯）做每个 agent 的红黄绿灯状态。
// 6 个中国风 agent 用内置静态目录渲染（离线也可见）；实时状态由 GET /tasks 聚合。

// MARK: - 数据模型

/// agent 当前灯态。idle=绿常亮 / working=黄呼吸 / asking=红闪 / offline=灭灰。
/// 标签用英文，语义对齐主灯(asking=红闪同主灯 Asking)。
enum AgentStatus {
    case offline, idle, working, asking

    var label: String {
        switch self {
        case .offline: return "offline"
        case .idle:    return "idle"
        case .working: return "working"
        case .asking:  return "asking"
        }
    }
}

/// 一个 agent 的静态档案。cmd 对齐 server COMMAND_REGISTRY。
struct AgentInfo: Identifiable {
    let cmd: String
    let name: String        // 鬼谷子
    let surname: String     // 头像字：鬼
    let role: String        // 选题官
    let blurb: String       // 一句话说明
    let icon: String        // SF Symbol（占位页/角色标识）
    let accent: Color       // 头像/主题色
    var id: String { cmd }
}

/// 内置目录：按生产链 + 重要度排序（操盘手在前，再到采集→选题→编剧→美术→声音）。
// title(role)/desc(blurb) 用各自成名典故；行尾注释保留真实职能,便于维护。
let agentCatalog: [AgentInfo] = [
    AgentInfo(cmd: "wolong",  name: "卧龙",   surname: "卧", role: "一统千军",
              blurb: "运筹帷幄之中，决胜千里之外",
              icon: "crown", accent: Color(red: 0.72, green: 0.20, blue: 0.18)),       // 操盘手:opus 编排全厂
    AgentInfo(cmd: "shenkuo", name: "沈括",   surname: "沈", role: "梦溪笔谈",
              blurb: "遍采百家，笔录天下爆款",
              icon: "tray.and.arrow.down", accent: Color(red: 0.18, green: 0.45, blue: 0.45)),  // 采集供料
    AgentInfo(cmd: "guiguzi", name: "鬼谷子", surname: "鬼", role: "捭阖纵横",
              blurb: "揣情摩意，谋定而后动",
              icon: "lightbulb", accent: Color(red: 0.30, green: 0.28, blue: 0.55)),   // 选题官
    AgentInfo(cmd: "liuyong", name: "柳永",   surname: "柳", role: "婉约词宗",
              blurb: "凡有井水处，皆能歌柳词",
              icon: "pencil.and.outline", accent: Color(red: 0.34, green: 0.45, blue: 0.25)),  // 编剧+质检
    AgentInfo(cmd: "wudaozi", name: "吴道子", surname: "吴", role: "吴带当风",
              blurb: "落笔成画，分镜传神",
              icon: "paintbrush.pointed", accent: Color(red: 0.25, green: 0.40, blue: 0.58)),  // 美术/分镜
    AgentInfo(cmd: "boya",    name: "伯牙",   surname: "伯", role: "高山流水",
              blurb: "鼓琴和鸣，众声成曲",
              icon: "waveform", accent: Color(red: 0.66, green: 0.30, blue: 0.40)),    // 声音
]

// MARK: - 卡片墙

struct AgentBoard: View {
    @State private var statusMap: [String: AgentStatus] = [:]
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Color.ctInk.opacity(0.55))
                }
            }
            .padding(.horizontal, 4)

            ForEach(agentCatalog) { agent in
                NavigationLink {
                    inbox(for: agent)
                } label: {
                    AgentCard(agent: agent, status: statusMap[agent.cmd] ?? .offline)
                }
                .buttonStyle(.plain)
            }
        }
        .task { await refreshStatus() }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await refreshStatus() } }) {
            ServerSettingsView()
        }
    }

    /// 每个 agent 的入口 = 通用收件箱 + 各自的详情/新建。
    /// 柳永是手工定制页(语音下选题/双稿对比);其余走通用详情(按 cmd 切专属成果面板)
    /// + schema 驱动的通用表单——新 agent 上架后端登记 schema 即可,端上零代码。
    @ViewBuilder
    private func inbox(for agent: AgentInfo) -> some View {
        if agent.cmd == "liuyong" {
            AgentTaskListView(agent: agent) { t in
                LiuyongTaskDetailView(taskId: t.task_id, topic: t.titleGuess, agent: agent)
            } compose: {
                LiuyongComposeSheet(agent: agent)
            }
        } else {
            AgentTaskListView(agent: agent) { t in
                AgentTaskDetailView(task: t, agent: agent)
            } compose: {
                AgentComposeSheet(agent: agent)
            }
        }
    }

    /// 拉 /tasks 按 cmd 聚合每个 agent 的实时灯态；服务器不可达则全部留 unknown(灭)。
    private func refreshStatus() async {
        do {
            let tasks = try await NofClient().listTasks()
            var map: [String: AgentStatus] = [:]
            for agent in agentCatalog {
                let mine = tasks.filter { $0.cmd == agent.cmd }
                if mine.contains(where: { $0.status == "running" }) {
                    map[agent.cmd] = .working
                } else if mine.contains(where: {
                    $0.status == "failed" || ($0.status == "completed" && $0.decision == nil)
                }) {
                    map[agent.cmd] = .asking
                } else {
                    map[agent.cmd] = .idle
                }
            }
            statusMap = map
        } catch {
            statusMap = [:]   // 离线：灯全灭，卡片仍在
        }
    }
}

// MARK: - 单张 agent 卡片

struct AgentCard: View {
    let agent: AgentInfo
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 14) {
            AgentAvatar(agent: agent)

            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name)
                    .font(.headline)
                    .foregroundStyle(Color.ctInk)
                Text(agent.role)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(agent.accent)
                Text(agent.blurb)
                    .font(.footnote)
                    .foregroundStyle(Color.ctInk.opacity(0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // 只留灯,去掉状态文字——文字宽度不一会把灯顶得左右错位,去掉后列方向对齐
            AgentStatusLight(status: status)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ctInk.opacity(0.25))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.ctCard)
        )
        .shadow(color: Color.ctInk.opacity(0.10), radius: 8, y: 4)
    }
}

/// 圆形渐变字号头像。
struct AgentAvatar: View {
    let agent: AgentInfo
    var size: CGFloat = 52

    var body: some View {
        Text(agent.surname)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(
                    LinearGradient(
                        colors: [agent.accent, agent.accent.opacity(0.75)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: agent.accent.opacity(0.35), radius: 5, y: 3)
    }
}

/// 每个 agent 的单灯状态指示：复用现有 TrafficBulb，颜色+动效语义与主灯一致——
/// 空闲=绿常亮 / 工作中=黄呼吸 / 待验收=红闪 / 离线=灭(灰底)。
struct AgentStatusLight: View {
    let status: AgentStatus
    var diameter: CGFloat = 16

    var body: some View {
        TrafficBulb(color: color, isOn: status != .offline, motion: motion,
                    period: period, dimTo: dimTo, diameter: diameter)
    }

    private var color: Color {
        switch status {
        case .offline: return .gray
        case .idle:    return .green
        case .working: return .ctAmber
        case .asking:  return .red
        }
    }

    private var motion: BulbMotion {
        switch status {
        case .working: return .breathe
        case .asking:  return .blink
        default:       return .solid
        }
    }

    private var period: Double {
        switch status {
        case .working: return 3.0
        case .asking:  return 0.7
        default:       return 1.0
        }
    }

    private var dimTo: Double { status == .working ? 0.4 : 1.0 }
}

// MARK: - 服务器地址设置（LAN 直连）

struct ServerSettingsView: View {
    @AppStorage(NofConfig.baseURLKey) private var baseURL: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NofConfig.defaultBaseURL, text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("内容工厂服务器")
                } footer: {
                    Text("留空用默认 \(NofConfig.defaultBaseURL)（Bonjour 主机名，换 WiFi 不用改）。个别路由器禁 mDNS 时再临时填 IP，如 http://192.168.1.20:8810。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

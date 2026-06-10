import SwiftUI
import UIKit

// agent 详情入口 = 该 agent 的任务收件箱。GET /tasks 筛 cmd，按状态分段：
// 运行中 / 待验收(默认,含失败) / 未开始(pending) / 已归档(已决策)。点卡片进任务详情。
// 列表层与新建层通用，可复用到全部 agent；任务详情页按 agent 定制。

enum TaskBucket: String, CaseIterable, Identifiable {
    case running  = "运行中"
    case review   = "待验收"
    case failed   = "已失败"
    case queued   = "未开始"
    case archived = "已归档"
    var id: String { rawValue }

    /// 优先级判定：已决策→归档；否则按 status。
    /// 失败独立成类(无产出可审,只待重试);completed 未决才进待验收。
    static func of(_ t: TaskMeta) -> TaskBucket {
        if t.decision != nil { return .archived }
        switch t.status {
        case "running": return .running
        case "pending": return .queued
        case "failed":  return .failed
        default:        return .review   // completed（未决）
        }
    }
}

/// ISO 时间串 -> "MM-dd HH:mm"，不依赖严格解析。
func shortTime(_ iso: String?) -> String {
    guard let iso else { return "" }
    let noFrac = iso.split(separator: ".").first.map(String.init) ?? iso
    let parts = noFrac.replacingOccurrences(of: "T", with: " ").split(separator: " ")
    guard parts.count == 2 else { return noFrac }
    return "\(parts[0].dropFirst(5)) \(parts[1].prefix(5))"
}

/// 呼吸点：运行中任务的活感指示，正弦缩放+亮度起伏（和主灯一脉相承）。
struct BreathingDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        TimelineView(.animation) { tl in
            let s = (sin(2 * .pi * tl.date.timeIntervalSinceReferenceDate / 2.2) + 1) / 2
            Circle().fill(color)
                .frame(width: size, height: size)
                .scaleEffect(0.8 + 0.35 * s)
                .opacity(0.55 + 0.45 * s)
                .shadow(color: color.opacity(0.7 * s), radius: 4 * s)
        }
    }
}

/// 卡片按压回弹：交互的呼吸/弹性感。
struct PressableCard: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

struct AgentTaskListView<Detail: View, Compose: View>: View {
    let agent: AgentInfo
    // 仅这两处随 agent 不同:点卡片进哪个详情页、"+"弹哪个新建表单。
    // 列表/分段/卡片全通用——新 agent 只需传这两个闭包。
    private let detail: (TaskMeta) -> Detail
    private let compose: () -> Compose

    init(
        agent: AgentInfo,
        @ViewBuilder detail: @escaping (TaskMeta) -> Detail,
        @ViewBuilder compose: @escaping () -> Compose
    ) {
        self.agent = agent
        self.detail = detail
        self.compose = compose
    }

    @State private var tasks: [TaskMeta] = []
    @State private var bucket: TaskBucket = .review
    @State private var loading = true
    @State private var loadError: String?
    @State private var showCompose = false

    private var mine: [TaskMeta] { tasks.filter { $0.cmd == agent.cmd } }
    private var shown: [TaskMeta] { mine.filter { TaskBucket.of($0) == bucket } }

    var body: some View {
        ZStack {
            Color.ctTan.ignoresSafeArea()
            VStack(spacing: 14) {
                header
                bucketSelector
                content
            }
            .padding(.top, 6)
        }
        // 去掉顶部中央的名字——标题位让位给上面的头像 hero
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCompose = true } label: { Image(systemName: "plus") }
                    .tint(Color.ctOrange)
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: $showCompose, onDismiss: { Task { await refresh() } }) {
            compose()
        }
    }

    // 头像 + 名字 + title（顶起,当页面标题用）
    private var header: some View {
        HStack(spacing: 12) {
            AgentAvatar(agent: agent, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.title3.weight(.bold)).foregroundStyle(Color.ctInk)
                Text(agent.role).font(.subheadline.weight(.semibold)).foregroundStyle(agent.accent)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // 暖色药丸分段（替掉系统 segmented 的灰底）
    private var bucketSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TaskBucket.allCases) { b in
                    let on = bucket == b
                    Button {
                        withAnimation(.snappy) { bucket = b }
                    } label: {
                        Text(b.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(on ? agent.accent : Color.ctCard)
                            .foregroundStyle(on ? .white : Color.ctInk.opacity(0.65))
                            .clipShape(Capsule())
                            .shadow(color: on ? agent.accent.opacity(0.3) : .clear, radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder private var content: some View {
        if loading {
            Spacer(); ProgressView().tint(Color.ctInk); Spacer()
        } else if let loadError {
            Spacer()
            ContentUnavailableView {
                Label("连不上服务器", systemImage: "wifi.slash")
            } description: {
                Text(loadError).font(.footnote)
            }
            Spacer()
        } else if shown.isEmpty {
            Spacer()
            ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(shown) { t in
                        NavigationLink {
                            detail(t)
                        } label: {
                            TaskCardView(task: t)
                        }
                        .buttonStyle(PressableCard())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .animation(.snappy, value: bucket)
            }
        }
    }

    private var emptyTitle: String {
        switch bucket {
        case .running:  return "暂无运行中任务"
        case .review:   return "没有待验收的任务"
        case .failed:   return "没有失败的任务"
        case .queued:   return "没有排队的任务"
        case .archived: return "归档为空"
        }
    }
    private var emptyIcon: String {
        switch bucket {
        case .running:  return "bolt.horizontal.circle"
        case .review:   return "tray"
        case .failed:   return "exclamationmark.triangle"
        case .queued:   return "clock"
        case .archived: return "archivebox"
        }
    }

    private func refresh() async {
        do {
            tasks = try await NofClient().listTasks()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - 任务卡（独立卡片）

struct TaskCardView: View {
    let task: TaskMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.titleGuess)
                .font(.headline)
                .foregroundStyle(Color.ctInk)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Label(shortTime(task.created_at), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(Color.ctInk.opacity(0.45))
                Spacer()
                statusChip   // 右下角
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ctCard))
        .shadow(color: Color.ctInk.opacity(0.08), radius: 6, y: 3)
    }

    @ViewBuilder private var statusChip: some View {
        if let d = task.decision {
            chip(d == "approved" ? "已采用" : "已打回",
                 d == "approved" ? .green : .red,
                 icon: d == "approved" ? "checkmark.seal.fill" : "arrow.uturn.backward")
        } else {
            switch task.status {
            case "running": chip("运行中", Color.ctAmber, breathing: true)
            case "pending": chip("排队中", Color.ctInk.opacity(0.5), icon: "hourglass")
            case "failed":  chip("已失败", .red, icon: "exclamationmark.triangle.fill")
            default:        chip("待验收", Color.ctOrange, icon: "tray.fill")
            }
        }
    }

    private func chip(_ t: String, _ c: Color, icon: String? = nil, breathing: Bool = false) -> some View {
        HStack(spacing: 5) {
            if breathing {
                BreathingDot(color: c)
            } else if let icon {
                Image(systemName: icon).font(.caption2)
            }
            Text(t).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(c.opacity(0.15)).foregroundStyle(c).clipShape(Capsule())
    }
}

// MARK: - 新建任务（柳永：下选题）

struct LiuyongComposeSheet: View {
    let agent: AgentInfo

    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var requirements = ""
    @State private var showAdvanced = false
    @State private var submitting = false
    @State private var errText: String?
    @StateObject private var dictator = SpeechDictator()

    var body: some View {
        NavigationStack {
            Form {
                Section("选题") {
                    TextField("一句话想法，如：同事阴阳你怎么办", text: $topic, axis: .vertical)
                        .lineLimit(2...5)
                    HStack {
                        Button {
                            if let s = UIPasteboard.general.string { topic = s }
                        } label: { Label("粘贴", systemImage: "doc.on.clipboard") }
                        Spacer()
                        Button { dictator.toggle() } label: {
                            Label(dictator.isRecording ? "停止" : "语音",
                                  systemImage: dictator.isRecording ? "stop.circle.fill" : "mic.fill")
                        }
                        .tint(dictator.isRecording ? .red : agent.accent)
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                }
                Section {
                    DisclosureGroup("附加创作要求（选填）", isExpanded: $showAdvanced) {
                        TextField("如：多举例、更口语、控制在 60 秒", text: $requirements, axis: .vertical)
                            .lineLimit(2...6)
                    }
                }
                if let errText {
                    Section { Text(errText).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("交给柳永")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发起") { Task { await submit() } }
                        .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting)
                }
            }
            .onAppear { dictator.requestAuthorization(); dictator.onError = { errText = $0 } }
            .onChange(of: dictator.transcript) { _, new in if dictator.isRecording { topic = new } }
        }
    }

    private func submit() async {
        submitting = true
        errText = nil
        if dictator.isRecording { dictator.stop() }
        do {
            _ = try await NofClient().createTask(
                cmd: agent.cmd,
                params: ["topic": topic, "user_requirements": requirements]
            )
            dismiss()
        } catch {
            errText = error.localizedDescription
            submitting = false
        }
    }
}

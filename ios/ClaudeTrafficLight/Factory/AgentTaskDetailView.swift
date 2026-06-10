import SwiftUI

// 通用单任务详情：SSE 进度(运行中实时/终态回放) -> 按 agent 渲染专属成果面板 ->
// 产物钻取 -> 验收通过/打回(语音说意见)。柳永有手工定制页;其余 agent 都走这里。
// 视觉语言对齐柳永页：暖象牙卡片 + 状态呼吸灯 + 实心/幽灵决策按钮 + 语音遮罩。

/// 各 agent 的强类型成果。按 cmd 解出对应面板的数据；形态对不上则 .plain(只剩产物区可审)。
enum AgentTaskResult {
    case guiguzi(GuiguziResult)
    case wudaozi(WudaoziResult)
    case boya(BoyaResult)
    case shenkuo(ShenkuoResult)
    case wolong(WolongResult)
    case plain
}

struct AgentTaskDetailView: View {
    let task: TaskMeta
    let agent: AgentInfo

    @State private var logs: [String] = []
    @State private var status: String?          // nil = 详情未拉到
    @State private var error: String?
    @State private var artifacts: [NofArtifact] = []
    @State private var review: NofReview?
    @State private var result: AgentTaskResult = .plain
    @State private var streamEnded = false
    @State private var reviewing = false
    @State private var errText: String?
    @State private var showRejectVoice = false
    @Environment(\.dismiss) private var dismiss

    private let client = NofClient()

    private var terminal: Bool { status == "completed" || status == "failed" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                resultPanel
                if !artifacts.isEmpty { ArtifactsCard(artifacts: artifacts, client: client) }
                if terminal && review == nil {
                    if status == "failed" { failedSection } else { decisionSection }
                }
                if let review { decidedBadge(review) }
                progressSection
            }
            .padding(20)
            .foregroundStyle(Color.ctInk)
        }
        .background(Color.ctTan.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await run() }
        .overlay {
            if showRejectVoice {
                RejectVoiceOverlay(
                    onCancel: { withAnimation { showRejectVoice = false } },
                    onConfirm: { text in Task { await confirmReject(text) } }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showRejectVoice)
    }

    // MARK: - Hero(头像 + 任务标题 + 灯态)

    private var hero: some View {
        HStack(spacing: 12) {
            AgentAvatar(agent: agent, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.titleGuess).font(.headline).foregroundStyle(Color.ctInk).lineLimit(2)
                HStack(spacing: 6) {
                    AgentStatusLight(status: lightStatus, diameter: 11)
                    Text(phaseWord).font(.caption.weight(.medium)).foregroundStyle(Color.ctInk.opacity(0.55))
                }
            }
            Spacer()
        }
    }

    private var lightStatus: AgentStatus {
        guard let status else { return streamEnded ? .idle : .working }
        if review != nil { return .idle }
        switch status {
        case "running", "pending": return .working
        case "failed", "completed": return .asking
        default: return .idle
        }
    }

    private var phaseWord: String {
        if let review { return review.decision == "approved" ? "已验收" : "已打回" }
        guard let status else { return streamEnded ? "处理中" : "\(agent.role)…" }
        switch status {
        case "running", "pending": return "工作中…"
        case "failed": return "已失败 · 待处理"
        case "completed": return "待验收"
        default: return ""
        }
    }

    // MARK: - 专属成果面板

    @ViewBuilder private var resultPanel: some View {
        switch result {
        case .guiguzi(let r): GuiguziTopicsPanel(result: r, agent: agent)
        case .wudaozi(let r): WudaoziStoryboardPanel(result: r, agent: agent)
        case .boya(let r):    BoyaSoundPanel(result: r, masterURL: masterAudioURL, agent: agent)
        case .shenkuo(let r): ShenkuoCollectPanel(result: r, agent: agent)
        case .wolong(let r):  WolongReportPanel(result: r, agent: agent)
        case .plain:          EmptyView()
        }
    }

    /// 伯牙 master.mp3 的可播放绝对地址(产物清单里 kind=audio 那条)。
    private var masterAudioURL: URL? {
        artifacts.first { $0.kind == "audio" }.flatMap { client.absoluteURL($0.url) }
    }

    // MARK: - 决策

    private var decisionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("决策").font(.headline)
            HStack(spacing: 12) {
                Button { withAnimation { showRejectVoice = true } } label: {
                    Label("打回", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(GhostDecisionButton(tint: .red))

                Button { Task { await approve() } } label: {
                    Label("验收通过", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(FilledDecisionButton(tint: Color(red: 0.20, green: 0.55, blue: 0.34)))
            }
            .disabled(reviewing)
            if let errText { Text(errText).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ctCard))
        .shadow(color: Color.ctInk.opacity(0.08), radius: 6, y: 3)
    }

    private func decidedBadge(_ r: NofReview) -> some View {
        let approved = r.decision == "approved"
        return VStack(alignment: .leading, spacing: 6) {
            Label(approved ? "已验收" : "已打回",
                  systemImage: approved ? "checkmark.seal.fill" : "arrow.uturn.backward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(approved ? Color(red: 0.20, green: 0.55, blue: 0.34) : .red)
            if let n = r.note, !n.isEmpty {
                Text(n).font(.footnote).foregroundStyle(Color.ctInk.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ctCard))
        .shadow(color: Color.ctInk.opacity(0.08), radius: 6, y: 3)
    }

    // MARK: - 失败(无产出可审,原参数重投)

    private var failedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("这条没跑成", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.red)
            if let error {
                Text(error).font(.footnote).foregroundStyle(Color.ctInk.opacity(0.6))
            }
            Button { Task { await retry() } } label: {
                Label("重新发起", systemImage: "arrow.clockwise")
            }
            .buttonStyle(FilledDecisionButton(tint: agent.accent))
            .disabled(reviewing)
            if let errText { Text(errText).font(.caption).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ctCard))
        .shadow(color: Color.ctInk.opacity(0.08), radius: 6, y: 3)
    }

    // MARK: - 进度

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("工作进度").font(.headline)
            if logs.isEmpty && !streamEnded {
                HStack(spacing: 8) { ProgressView(); Text("等待\(agent.name)输出…").foregroundStyle(.secondary) }
            }
            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(for: line))
                        .font(.caption2).foregroundStyle(agent.accent).padding(.top, 2)
                    Text(line).font(.footnote).foregroundStyle(Color.ctInk.opacity(0.8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func icon(for line: String) -> String {
        if line.contains("打回") || line.contains("重写") || line.contains("重切") { return "arrow.triangle.2.circlepath" }
        if line.contains("质检") || line.contains("校验") { return "checkmark.shield" }
        if line.contains("异常") || line.contains("失败") { return "exclamationmark.triangle" }
        if line.contains("完成") { return "flag.checkered" }
        if line.contains("启动") { return "play.circle" }
        return "circle.fill"
    }

    // MARK: - 行为

    private func run() async {
        do {
            for try await ev in client.events(task.task_id) {
                if ev.type == "progress", let t = ev.text { logs.append(t) }
                if ev.type == "error", let e = ev.error { errText = e }
            }
        } catch {
            errText = error.localizedDescription
        }
        streamEnded = true
        await loadDetail()
    }

    /// 同一份 GET /tasks/{id},按 cmd 解成对应 agent 的强类型 result。
    private func loadDetail() async {
        switch agent.cmd {
        case "guiguzi":
            if let d = try? await client.typedTask(task.task_id, as: GuiguziResult.self) {
                apply(d, d.result.map(AgentTaskResult.guiguzi))
            }
        case "wudaozi":
            if let d = try? await client.typedTask(task.task_id, as: WudaoziResult.self) {
                apply(d, d.result.map(AgentTaskResult.wudaozi))
            }
        case "boya":
            if let d = try? await client.typedTask(task.task_id, as: BoyaResult.self) {
                apply(d, d.result.map(AgentTaskResult.boya))
            }
        case "shenkuo":
            if let d = try? await client.typedTask(task.task_id, as: ShenkuoResult.self) {
                apply(d, d.result.map(AgentTaskResult.shenkuo))
            }
        case "wolong":
            if let d = try? await client.typedTask(task.task_id, as: WolongResult.self) {
                apply(d, d.result.map(AgentTaskResult.wolong))
            }
        default:
            if let d = try? await client.typedTask(task.task_id, as: WolongResult.self) {
                apply(d, nil)   // 未知 cmd:只用公共字段,产物区兜底
            }
        }
    }

    private func apply<R>(_ d: TaskDetailTyped<R>, _ r: AgentTaskResult?) {
        status = d.status
        error = d.error
        artifacts = d.artifacts ?? []
        review = d.review
        result = r ?? .plain
    }

    private func approve() async {
        reviewing = true; errText = nil
        do {
            _ = try await client.review(task.task_id, decision: "approved", note: nil)
            await loadDetail()
        } catch {
            errText = error.localizedDescription
        }
        reviewing = false
    }

    private func confirmReject(_ text: String) async {
        withAnimation { showRejectVoice = false }
        reviewing = true; errText = nil
        do {
            _ = try await client.review(task.task_id, decision: "rejected", note: text)
            await loadDetail()
        } catch {
            errText = error.localizedDescription
        }
        reviewing = false
    }

    private func retry() async {
        reviewing = true; errText = nil
        do {
            _ = try await client.createTask(cmd: agent.cmd, params: task.paramsAny)
            dismiss()
        } catch {
            errText = error.localizedDescription
            reviewing = false
        }
    }
}

// MARK: - 产物卡(把 List 风格的 ArtifactRow 装进暖色卡片)

struct ArtifactsCard: View {
    let artifacts: [NofArtifact]
    let client: NofClient

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("产物 · 审看").font(.headline)
            ForEach(Array(artifacts.enumerated()), id: \.element.id) { i, art in
                if i > 0 { Divider() }
                NavigationLink {
                    ArtifactViewer(artifact: art, client: client)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: artifactIcon(art.kind))
                            .font(.body)
                            .foregroundStyle(Color.ctOrange)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(art.label).font(.subheadline).foregroundStyle(Color.ctInk)
                            Text(art.kind).font(.caption2).foregroundStyle(Color.ctInk.opacity(0.4))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ctInk.opacity(0.25))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ctCard))
        .shadow(color: Color.ctInk.opacity(0.08), radius: 6, y: 3)
    }

    private func artifactIcon(_ kind: String) -> String {
        switch kind {
        case "script", "text": return "doc.text"
        case "audio": return "waveform"
        case "video": return "play.rectangle"
        case "image": return "photo"
        case "data": return "curlybraces"
        case "dir": return "folder"
        default: return "doc"
        }
    }
}

import SwiftUI

// 柳永单任务详情：SSE 进度(运行中实时/终态回放) -> 双稿对比 -> 质检面板 -> 采用/打回。
// 采用 = 直接记 approved；打回 = 遮罩层语音说打回意见 -> 记 rejected + 当新要求重投。
// 样式与任务列表一致：暖色卡片(ctCard+阴影) + 药丸切换 + 呼吸/弹性交互。

private let RUBRIC_DIMS = ["节奏", "真实性", "精炼度", "直接性", "信任度"]

func liuyongMarkdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

/// 统一卡面：暖象牙圆角 + 柔和阴影。
private func cardBG() -> some View {
    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ctCard)
}

struct LiuyongTaskDetailView: View {
    let taskId: String
    let topic: String
    let agent: AgentInfo

    @State private var logs: [String] = []
    @State private var detail: TaskDetailLiuyong?
    @State private var streamEnded = false
    @State private var selected = 0
    @State private var reviewing = false
    @State private var errText: String?
    @State private var resubmitted = false
    @State private var showRejectVoice = false
    @Environment(\.dismiss) private var dismiss

    private var drafts: [LiuyongDraft] { detail?.result?.drafts ?? [] }
    private var current: LiuyongDraft? { drafts.indices.contains(selected) ? drafts[selected] : nil }
    private var terminal: Bool { detail?.status == "completed" || detail?.status == "failed" }

    private var lightStatus: AgentStatus {
        guard let d = detail else { return streamEnded ? .idle : .working }
        if d.review != nil { return .idle }
        switch d.status {
        case "running", "pending": return .working
        case "failed", "completed": return .asking
        default: return .idle
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                if !drafts.isEmpty { draftsSection }
                if let d = current { QCReportView(draft: d) }
                if terminal && detail?.review == nil && !resubmitted {
                    if drafts.isEmpty { failedSection } else { decisionSection }
                }
                if let r = detail?.review { decidedBadge(r) }
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

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 12) {
            AgentAvatar(agent: agent, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(topic).font(.headline).foregroundStyle(Color.ctInk).lineLimit(2)
                HStack(spacing: 6) {
                    AgentStatusLight(status: lightStatus, diameter: 11)
                    Text(phaseWord).font(.caption.weight(.medium)).foregroundStyle(Color.ctInk.opacity(0.55))
                }
            }
            Spacer()
        }
    }

    private var phaseWord: String {
        if let r = detail?.review { return r.decision == "approved" ? "已采用" : "已打回" }
        guard let d = detail else { return streamEnded ? "处理中" : "创作中…" }
        switch d.status {
        case "running", "pending": return "创作中…"
        case "failed": return "已失败 · 待处理"
        case "completed": return "待验收"
        default: return ""
        }
    }

    // MARK: 双稿（药丸切换 + 稿件卡）

    private var draftsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if drafts.count > 1 {
                HStack(spacing: 8) {
                    ForEach(Array(drafts.enumerated()), id: \.offset) { i, d in
                        let on = selected == i
                        Button { withAnimation(.snappy) { selected = i } } label: {
                            Text(d.model ?? "稿\(i + 1)")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(on ? agent.accent : Color.ctCard)
                                .foregroundStyle(on ? .white : Color.ctInk.opacity(0.6))
                                .clipShape(Capsule())
                                .shadow(color: on ? agent.accent.opacity(0.3) : .clear, radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
            if let d = current {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(d.model ?? "稿件").font(.subheadline.weight(.bold))
                        Spacer()
                        verdictBadge(d.qc?.verdict)
                        rubricChip(d.qc_rubric)
                    }
                    Divider()
                    Text(liuyongMarkdown(d.text ?? "(空稿)"))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(cardBG())
                .shadow(color: Color.ctInk.opacity(0.08), radius: 6, y: 3)
            }
        }
    }

    @ViewBuilder private func verdictBadge(_ v: String?) -> some View {
        if let v {
            let pass = v == "pass"
            Label(pass ? "AI味 通过" : "AI味 打回",
                  systemImage: pass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background((pass ? Color.green : .red).opacity(0.16))
                .foregroundStyle(pass ? Color.green : .red)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder private func rubricChip(_ r: RubricQC?) -> some View {
        if let r, r.available == true, let total = r.total {
            Text("\(total)/50 · \(r.grade ?? "")")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.ctOrange.opacity(0.16))
                .foregroundStyle(Color.ctOrange)
                .clipShape(Capsule())
        }
    }

    // MARK: 决策（两个高级感按钮）

    private var decisionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("决策").font(.headline)
            HStack(spacing: 12) {
                Button { withAnimation { showRejectVoice = true } } label: {
                    Label("打回重写", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(GhostDecisionButton(tint: .red))

                Button { Task { await approve() } } label: {
                    Label("采用此稿", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(FilledDecisionButton(tint: Color(red: 0.20, green: 0.55, blue: 0.34)))
            }
            .disabled(reviewing)
            if let errText { Text(errText).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .background(cardBG())
        .shadow(color: Color.ctInk.opacity(0.08), radius: 6, y: 3)
    }

    private func decidedBadge(_ r: NofReview) -> some View {
        let approved = r.decision == "approved"
        return VStack(alignment: .leading, spacing: 6) {
            Label(approved ? "已采用" : "已打回",
                  systemImage: approved ? "checkmark.seal.fill" : "arrow.uturn.backward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(approved ? Color(red: 0.20, green: 0.55, blue: 0.34) : .red)
            if let n = r.note, !n.isEmpty {
                Text(n).font(.footnote).foregroundStyle(Color.ctInk.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBG())
        .shadow(color: Color.ctInk.opacity(0.08), radius: 6, y: 3)
    }

    // MARK: 失败(无稿可审 -> 不显示采用,只给重新发起)

    private var failedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("这条没跑成", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.red)
            if let e = detail?.error {
                Text(e).font(.footnote).foregroundStyle(Color.ctInk.opacity(0.6))
            }
            Button { Task { await retry() } } label: {
                Label("重新发起", systemImage: "arrow.clockwise")
            }
            .buttonStyle(FilledDecisionButton(tint: agent.accent))
            .disabled(reviewing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBG())
        .shadow(color: Color.ctInk.opacity(0.08), radius: 6, y: 3)
    }

    // MARK: 进度

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("创作进度").font(.headline)
            if logs.isEmpty && !streamEnded {
                HStack(spacing: 8) { ProgressView(); Text("等待柳永输出…").foregroundStyle(.secondary) }
            }
            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(for: line))
                        .font(.caption2).foregroundStyle(agent.accent).padding(.top, 2)
                    Text(line).font(.footnote).foregroundStyle(Color.ctInk.opacity(0.8))
                }
            }
            if let e = detail?.error { Text(e).font(.footnote).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func icon(for line: String) -> String {
        if line.contains("打回") || line.contains("重写") { return "arrow.triangle.2.circlepath" }
        if line.contains("质检") { return "checkmark.shield" }
        if line.contains("完成") { return "flag.checkered" }
        if line.contains("启动") { return "play.circle" }
        return "circle.fill"
    }

    // MARK: 行为

    private func run() async {
        do {
            for try await ev in NofClient().events(taskId) {
                if ev.type == "progress", let t = ev.text { logs.append(t) }
                if ev.type == "error", let e = ev.error { errText = e }
            }
        } catch {
            errText = error.localizedDescription
        }
        streamEnded = true
        await loadDetail()
    }

    private func loadDetail() async {
        detail = try? await NofClient().liuyongTask(taskId)
    }

    private func approve() async {
        reviewing = true; errText = nil
        let model = current?.model ?? ""
        do {
            _ = try await NofClient().review(taskId, decision: "approved", note: "采用 \(model) 稿")
            await loadDetail()
        } catch {
            errText = error.localizedDescription
        }
        reviewing = false
    }

    private func retry() async {
        reviewing = true; errText = nil
        do {
            _ = try await NofClient().createTask(cmd: agent.cmd, params: ["topic": topic])
            resubmitted = true
            dismiss()
        } catch {
            errText = error.localizedDescription
            reviewing = false
        }
    }

    private func confirmReject(_ text: String) async {
        withAnimation { showRejectVoice = false }
        reviewing = true; errText = nil
        do {
            _ = try? await NofClient().review(taskId, decision: "rejected", note: text)
            let extra = text.isEmpty ? "" : "【打回意见】\(text)"
            _ = try await NofClient().createTask(
                cmd: agent.cmd,
                params: ["topic": topic, "user_requirements": extra]
            )
            resubmitted = true
            dismiss()
        } catch {
            errText = error.localizedDescription
            reviewing = false
        }
    }
}

// MARK: - 高级感决策按钮

/// 实心：渐变填充 + 柔光 + 按压回弹（采用此稿用）。
struct FilledDecisionButton: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(.white)
            .background(
                LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .shadow(color: tint.opacity(configuration.isPressed ? 0.15 : 0.4), radius: 9, y: 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// 描边幽灵：象牙底 + 细色边 + 按压回弹（打回重写用，次要动作）。
struct GhostDecisionButton: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.ctCard))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(tint.opacity(0.5), lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

// MARK: - 打回语音遮罩层（底部居中麦克风 + 上方实时听写）

struct RejectVoiceOverlay: View {
    var onCancel: () -> Void
    var onConfirm: (String) -> Void

    @StateObject private var dictator = SpeechDictator()
    @State private var err: String?
    private let tint = Color(red: 0.80, green: 0.26, blue: 0.22)

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()   // 加深,挡住下方文字

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { stop(); onCancel() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(20)

                Spacer()

                // 上方:实时听写内容
                Text(dictator.transcript.isEmpty ? "说出打回意见…" : dictator.transcript)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(dictator.transcript.isEmpty ? .white.opacity(0.45) : .white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .frame(minHeight: 80)

                if let err {
                    Text(err).font(.footnote).foregroundStyle(.white.opacity(0.7)).padding(.top, 6)
                }

                Spacer()

                // 底部居中:麦克风 + 提示 + 确认
                VStack(spacing: 18) {
                    micButton
                    Text(dictator.isRecording ? "正在聆听… 点击停止" : "点击麦克风说话")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                    Button {
                        stop()
                        onConfirm(dictator.transcript)
                    } label: {
                        Label("确认打回", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(FilledDecisionButton(tint: tint))
                    .disabled(dictator.transcript.isEmpty)
                    .opacity(dictator.transcript.isEmpty ? 0.5 : 1)
                    .padding(.horizontal, 48)
                }
                .padding(.bottom, 44)
            }
        }
        .onAppear {
            dictator.requestAuthorization()
            dictator.onError = { err = $0 }
            dictator.start()
        }
    }

    private var micButton: some View {
        Button { dictator.toggle() } label: {
            ZStack {
                if dictator.isRecording {
                    TimelineView(.animation) { tl in
                        let s = (sin(2 * .pi * tl.date.timeIntervalSinceReferenceDate / 1.6) + 1) / 2
                        Circle().stroke(tint.opacity(0.6), lineWidth: 3)
                            .frame(width: 84 + 26 * s, height: 84 + 26 * s)
                            .opacity(1 - s)
                    }
                }
                Circle()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 84, height: 84)
                    .shadow(color: tint.opacity(0.5), radius: 14, y: 6)
                Image(systemName: dictator.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 32, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private func stop() { if dictator.isRecording { dictator.stop() } }
}

// MARK: - 质检报告（AI 味命中 + rubric 五维 Gauge）

struct QCReportView: View {
    let draft: LiuyongDraft

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                aiTaste
                rubric
            }
            .padding(.top, 8)
        } label: {
            Label("质检报告", systemImage: "checkmark.shield").font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ctCard))
        .shadow(color: Color.ctInk.opacity(0.08), radius: 6, y: 3)
    }

    @ViewBuilder private var aiTaste: some View {
        if let qc = draft.qc {
            VStack(alignment: .leading, spacing: 6) {
                Text("AI 味扫描").font(.footnote.weight(.bold))
                Text(qc.summary ?? "").font(.caption).foregroundStyle(Color.ctInk.opacity(0.6))
                let hits = (qc.density ?? []) + (qc.hard ?? [])
                if hits.isEmpty {
                    Label("无命中句式", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                } else {
                    ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("• \(h.rule ?? "?") ×\(h.count ?? 0)").font(.caption.weight(.medium))
                            if let s = h.samples, !s.isEmpty {
                                Text(s.joined(separator: " / ")).font(.caption2)
                                    .foregroundStyle(Color.ctInk.opacity(0.5)).lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var rubric: some View {
        if let r = draft.qc_rubric {
            VStack(alignment: .leading, spacing: 8) {
                Text("质量评分（opus rubric）").font(.footnote.weight(.bold))
                if r.available == true, let dims = r.dims {
                    ForEach(RUBRIC_DIMS, id: \.self) { dim in
                        let v = dims[dim] ?? 0
                        Gauge(value: Double(v), in: 0...10) {
                            Text(dim)
                        } currentValueLabel: {
                            Text("\(v)")
                        }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(v >= 8 ? .green : v >= 6 ? Color.ctAmber : .red)
                        .font(.caption2)
                    }
                    HStack {
                        Text("总分").font(.caption.weight(.bold))
                        Spacer()
                        Text("\(r.total ?? 0)/50 · \(r.grade ?? "")").font(.caption.weight(.bold))
                            .foregroundStyle(Color.ctOrange)
                    }
                    if let issues = r.issues, !issues.isEmpty {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, s in
                            Text("· \(s)").font(.caption2).foregroundStyle(Color.ctInk.opacity(0.6))
                        }
                    }
                    Text("校准期，分数仅供参考").font(.caption2).foregroundStyle(Color.ctInk.opacity(0.35))
                } else {
                    Text("rubric 跳过（\(r.skipped ?? "opus 不可用")）")
                        .font(.caption).foregroundStyle(Color.ctInk.opacity(0.5))
                }
            }
        }
    }
}

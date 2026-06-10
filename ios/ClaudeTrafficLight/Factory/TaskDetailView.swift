import SwiftUI

// 一个任务的全生命周期视图：SSE 看进度 -> 终态读产物 -> 点同意/拒绝(+语音备注)。

struct TaskDetailView: View {
    let taskId: String
    let cmdLabel: String
    let client: NofClient

    @State private var logs: [String] = []
    @State private var detail: TaskDetail?
    @State private var streamEnded = false
    @State private var streamError: String?

    @State private var note: String = ""
    @State private var reviewing = false
    @State private var reviewError: String?

    @StateObject private var dictator = SpeechDictator()

    var body: some View {
        List {
            statusSection
            if let detail, let arts = detail.artifacts, !arts.isEmpty {
                Section("产物 · 审看") {
                    ForEach(arts) { ArtifactRow(artifact: $0, client: client) }
                }
            }
            if streamEnded { decisionSection }
            progressSection
        }
        .navigationTitle(cmdLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task { await runStream() }
        .onAppear { dictator.onError = { reviewError = $0 } }
        .onChange(of: dictator.transcript) { _, new in if dictator.isRecording { note = new } }
    }

    // MARK: 状态

    private var statusSection: some View {
        Section {
            HStack {
                Text("状态")
                Spacer()
                if let d = detail {
                    statusBadge(d.status)
                } else if streamEnded {
                    statusBadge("completed")
                } else {
                    ProgressView()
                }
            }
            if let r = detail?.review {
                HStack {
                    Text("决策")
                    Spacer()
                    decisionBadge(r.decision)
                }
                if let n = r.note, !n.isEmpty {
                    Text(n).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let e = detail?.error ?? streamError {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // MARK: 决策

    private var decisionSection: some View {
        Section("决策") {
            TextField("备注（可选，可语音）", text: $note, axis: .vertical)
                .lineLimit(1...4)
            HStack {
                Button {
                    if dictator.isRecording { dictator.stop() } else { dictator.start() }
                } label: {
                    Label(dictator.isRecording ? "停止" : "语音备注",
                          systemImage: dictator.isRecording ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(.bordered)
                .tint(dictator.isRecording ? .red : .accentColor)
                Spacer()
            }
            HStack(spacing: 12) {
                Button { Task { await submit("rejected") } } label: {
                    Label("拒绝", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red)

                Button { Task { await submit("approved") } } label: {
                    Label("同意", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.green)
            }
            .disabled(reviewing)
            if let reviewError {
                Text(reviewError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: 进度日志

    private var progressSection: some View {
        Section("进度") {
            if logs.isEmpty && !streamEnded {
                Text("等待 agent 输出…").foregroundStyle(.secondary)
            }
            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.footnote, design: .monospaced))
            }
        }
    }

    // MARK: 行为

    private func runStream() async {
        do {
            for try await ev in client.events(taskId) {
                switch ev.type {
                case "progress": if let t = ev.text { logs.append(t) }
                case "error": streamError = ev.error
                default: break
                }
            }
        } catch {
            streamError = error.localizedDescription
        }
        streamEnded = true
        await loadDetail()
    }

    private func loadDetail() async {
        detail = try? await client.task(taskId)
    }

    private func submit(_ decision: String) async {
        if dictator.isRecording { dictator.stop() }
        reviewing = true
        reviewError = nil
        do {
            _ = try await client.review(taskId, decision: decision, note: note)
            await loadDetail()
        } catch {
            reviewError = error.localizedDescription
        }
        reviewing = false
    }

    // MARK: 小组件

    private func statusBadge(_ s: String) -> some View {
        let color: Color = s == "completed" ? .green : s == "failed" ? .red
            : s == "running" ? .orange : .gray
        return Text(s).font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
    }

    private func decisionBadge(_ d: String) -> some View {
        let approved = d == "approved"
        return Label(approved ? "已同意" : "已拒绝",
                     systemImage: approved ? "checkmark.seal.fill" : "xmark.seal.fill")
            .font(.caption).foregroundStyle(approved ? .green : .red)
    }
}

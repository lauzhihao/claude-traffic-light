import SwiftUI
import AVKit
import Combine

// 五个 agent 的专属成果面板：从强类型 result 渲染差异化审看 UI。
// 统一卡面语言(暖象牙圆角卡 + 柔和阴影 + accent 点缀)，只做审看必需的信息层级，不堆装饰。
// 鬼谷子面板带一个真实的生产链动作：选题一键「交给柳永」。

/// 统一卡面修饰，与柳永页/任务卡同款。
private struct ResultCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ctCard))
            .shadow(color: Color.ctInk.opacity(0.08), radius: 6, y: 3)
    }
}

private extension View {
    func resultCard() -> some View { modifier(ResultCard()) }
}

/// 小胶囊标签(分镜动效/场景/工序状态等)。
private func tagChip(_ text: String, _ color: Color, icon: String? = nil) -> some View {
    HStack(spacing: 3) {
        if let icon { Image(systemName: icon).font(.system(size: 9)) }
        Text(text).font(.caption2.weight(.medium))
    }
    .padding(.horizontal, 7).padding(.vertical, 3)
    .background(color.opacity(0.14)).foregroundStyle(color).clipShape(Capsule())
}

// MARK: - 鬼谷子:选题库(排名 + 潜力分 + 一键交给柳永)

struct GuiguziTopicsPanel: View {
    let result: GuiguziResult
    let agent: AgentInfo

    @State private var sent: Set<Int> = []
    @State private var sending: Set<Int> = []
    @State private var errText: String?

    private var topics: [GuiguziTopic] { result.topics ?? [] }
    // 下游编剧的主题色,从内置目录取(找不到就用本 agent 色,不至于崩样式)
    private var liuyongAccent: Color {
        agentCatalog.first { $0.cmd == "liuyong" }?.accent ?? agent.accent
    }

    var body: some View {
        if topics.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("选题库").font(.headline)
                    Spacer()
                    Text("\(topics.count) 条").font(.caption).foregroundStyle(Color.ctInk.opacity(0.45))
                }
                ForEach(Array(topics.enumerated()), id: \.offset) { i, t in
                    if i > 0 { Divider() }
                    topicRow(i, t)
                }
                if let errText { Text(errText).font(.caption).foregroundStyle(.red) }
            }
            .resultCard()
        }
    }

    private func topicRow(_ i: Int, _ t: GuiguziTopic) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(i + 1)")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(agent.accent.opacity(i < 3 ? 1 : 0.45)))
                Text(t.title ?? "(无标题)")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let p = t.potential {
                    Text("潜力 \(Int(p))")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(potentialColor(p).opacity(0.15))
                        .foregroundStyle(potentialColor(p))
                        .clipShape(Capsule())
                }
            }
            if let m = t.motif, !m.isEmpty {
                Text("母题 · \(m)").font(.caption).foregroundStyle(Color.ctInk.opacity(0.65))
            }
            if let w = t.why, !w.isEmpty {
                Text(w).font(.caption).foregroundStyle(agent.accent.opacity(0.9))
            }
            HStack {
                if let s = t.source, !s.isEmpty {
                    Text("对标 · \(s)").font(.caption2).foregroundStyle(Color.ctInk.opacity(0.4)).lineLimit(1)
                }
                Spacer()
                handOffButton(i, t)
            }
        }
        .padding(.vertical, 2)
    }

    /// 生产链下一站:把选题直接投给柳永写稿。
    @ViewBuilder private func handOffButton(_ i: Int, _ t: GuiguziTopic) -> some View {
        if sent.contains(i) {
            Label("已交柳永", systemImage: "checkmark")
                .font(.caption2.weight(.semibold)).foregroundStyle(.green)
        } else {
            Button {
                Task { await handOff(i, t) }
            } label: {
                Label("交给柳永", systemImage: "paperplane.fill")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(liuyongAccent.opacity(0.14))
                    .foregroundStyle(liuyongAccent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(sending.contains(i) || (t.title ?? "").isEmpty)
            .opacity(sending.contains(i) ? 0.5 : 1)
        }
    }

    private func potentialColor(_ p: Double) -> Color {
        p >= 8 ? .green : p >= 6 ? Color.ctAmber : Color.ctInk.opacity(0.5)
    }

    private func handOff(_ i: Int, _ t: GuiguziTopic) async {
        guard let title = t.title, !title.isEmpty else { return }
        sending.insert(i); errText = nil
        do {
            _ = try await NofClient().createTask(cmd: "liuyong", params: ["topic": title])
            sent.insert(i)
        } catch {
            errText = error.localizedDescription
        }
        sending.remove(i)
    }
}

// MARK: - 吴道子:不丢句质检 + 分镜表

struct WudaoziStoryboardPanel: View {
    let result: WudaoziResult
    let agent: AgentInfo

    private var beats: [WudaoziBeat] { result.beats ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            qcCard
            if !beats.isEmpty { beatsCard }
        }
    }

    @ViewBuilder private var qcCard: some View {
        if let qc = result.qc {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("分镜质检").font(.headline)
                    Spacer()
                    let pass = qc.verdict == "pass"
                    tagChip(pass ? "不丢句 通过" : "不丢句 未过",
                            pass ? .green : .red,
                            icon: pass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                }
                if let r = qc.ratio {
                    Gauge(value: min(max(r, 0), 1)) {
                        Text("原文覆盖率")
                    } currentValueLabel: {
                        Text(String(format: "%.1f%%", r * 100))
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(r >= 0.98 ? .green : r >= 0.9 ? Color.ctAmber : .red)
                    .font(.caption2)
                }
                ForEach(Array((qc.warnings ?? []).enumerated()), id: \.offset) { _, w in
                    Label(w, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(Color.ctAmber)
                }
                Text("吴道子只出分镜;成片 mp4 需再发起 render 任务")
                    .font(.caption2).foregroundStyle(Color.ctInk.opacity(0.35))
            }
            .resultCard()
        }
    }

    private var beatsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("分镜").font(.headline)
                Spacer()
                Text("\(beats.count) 句").font(.caption).foregroundStyle(Color.ctInk.opacity(0.45))
            }
            ForEach(Array(beats.enumerated()), id: \.offset) { i, b in
                if i > 0 { Divider() }
                beatRow(i, b)
            }
        }
        .resultCard()
    }

    private func beatRow(_ i: Int, _ b: WudaoziBeat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(i + 1)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(agent.accent)
                .frame(width: 22, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(b.zh ?? "").font(.callout)
                HStack(spacing: 6) {
                    if let f = b.figure {
                        tagChip(figureName(f), agent.accent, icon: "person.fill")
                    } else {
                        tagChip("纯字幕", Color.ctInk.opacity(0.45), icon: "captions.bubble")
                    }
                    if let m = b.motion { tagChip(m, Color.ctOrange, icon: "wind") }
                    if let icons = b.icons, !icons.isEmpty {
                        Text(icons.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(Color.ctInk.opacity(0.4)).lineLimit(1)
                    }
                }
            }
        }
    }

    private func figureName(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}

// MARK: - 伯牙:声音床(master 试听 + 配乐/音效 + 听感质检)

struct BoyaSoundPanel: View {
    let result: BoyaResult
    let masterURL: URL?
    let agent: AgentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            masterCard
            mixCard
        }
    }

    private var masterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("成品混音").font(.headline)
                Spacer()
                if let s = result.scene { tagChip(s, agent.accent, icon: "theatermasks") }
            }
            InlineAudioPlayer(url: masterURL, title: "master.mp3", subtitle: voiceLine, accent: agent.accent)
            auditionRow
        }
        .resultCard()
    }

    private var voiceLine: String {
        let clips = result.voice?.clips.map { "\($0) 句人声" }
        let dur = result.voice?.duration_s.map { String(format: "%.0f 秒", $0) }
        return [clips, dur].compactMap(\.self).joined(separator: " · ")
    }

    @ViewBuilder private var auditionRow: some View {
        if let a = result.audition {
            VStack(alignment: .leading, spacing: 4) {
                let ok = a.verdict == "ok"
                Label(ok ? "听感质检 通过" : "听感质检 提醒",
                      systemImage: ok ? "checkmark.seal.fill" : "ear.trianglebadge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ok ? .green : Color.ctAmber)
                ForEach(Array((a.notes ?? []).enumerated()), id: \.offset) { _, n in
                    Text("· \(n)").font(.caption2).foregroundStyle(Color.ctInk.opacity(0.55))
                }
            }
        }
    }

    private var mixCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("声音方案").font(.headline)
            // BGM
            HStack(spacing: 10) {
                Image(systemName: "music.note").foregroundStyle(agent.accent).frame(width: 22)
                if let bgm = result.bgm, let f = bgm.file {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(URL(fileURLWithPath: f).lastPathComponent)
                                .font(.subheadline.weight(.medium))
                            if let v = bgm.volume_db {
                                Text(String(format: "%.0f dB", v))
                                    .font(.caption2).foregroundStyle(Color.ctInk.opacity(0.45))
                            }
                        }
                        if let r = bgm.reason {
                            Text(r).font(.caption2).foregroundStyle(Color.ctInk.opacity(0.45))
                        }
                    }
                } else {
                    Text("未配 BGM（库内无可用）")
                        .font(.subheadline).foregroundStyle(Color.ctInk.opacity(0.45))
                }
                Spacer()
            }
            // SFX
            let cues = result.sfx ?? []
            if cues.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2").foregroundStyle(agent.accent).frame(width: 22)
                    Text("无音效 cue").font(.subheadline).foregroundStyle(Color.ctInk.opacity(0.45))
                    Spacer()
                }
            } else {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(cues.enumerated()), id: \.offset) { _, c in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text("#\(c.beat ?? 0)").font(.caption2.weight(.bold)).foregroundStyle(agent.accent)
                                    Text(c.cue ?? "").font(.caption.weight(.medium))
                                    if let t = c.time_s {
                                        Text(String(format: "@ %.1fs", t))
                                            .font(.caption2).foregroundStyle(Color.ctInk.opacity(0.45))
                                    }
                                }
                                if let r = c.reason {
                                    Text(r).font(.caption2).foregroundStyle(Color.ctInk.opacity(0.4))
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.2").foregroundStyle(agent.accent).frame(width: 22)
                        Text("音效 · \(cues.count) 处").font(.subheadline.weight(.medium))
                    }
                }
                .tint(Color.ctInk.opacity(0.5))
            }
        }
        .resultCard()
    }
}

/// 极简内嵌播放器：播放/暂停 + 标题行。审听 master 不必跳全屏播放器。
struct InlineAudioPlayer: View {
    let url: URL?
    let title: String
    let subtitle: String?
    let accent: Color

    @State private var player: AVPlayer?
    @State private var playing = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(url == nil ? Color.ctInk.opacity(0.25) : accent)
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Color.ctInk.opacity(0.5))
                }
            }
            Spacer()
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(accent.opacity(playing ? 0.9 : 0.35))
                .symbolEffect(.variableColor.iterative, isActive: playing)
        }
        .onDisappear { player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            // 只响应自己的 item:播完复位成可重播
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            playing = false
            player?.seek(to: .zero)
        }
    }

    private func toggle() {
        guard let url else { return }
        if player == nil { player = AVPlayer(url: url) }
        if playing { player?.pause() } else { player?.play() }
        playing.toggle()
    }
}

// MARK: - 沈括:采集战果(统计 + 逐条工序状态)

struct ShenkuoCollectPanel: View {
    let result: ShenkuoResult
    let agent: AgentInfo

    private var entries: [ShenkuoEntry] { result.collected ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("采集战果").font(.headline)
                Spacer()
                if let n = result.all_posts { tagChip("拉取 \(n) 条", agent.accent, icon: "tray.and.arrow.down") }
                if let s = result.snapshots { tagChip("快照 \(s)", Color.ctOrange, icon: "chart.line.uptrend.xyaxis") }
            }
            if entries.isEmpty {
                Text(result.snapshots != nil ? "本次仅刷新作品指标，未深采" : "没有采到内容")
                    .font(.footnote).foregroundStyle(Color.ctInk.opacity(0.5))
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                    if i > 0 { Divider() }
                    entryRow(e)
                }
            }
        }
        .resultCard()
    }

    private func entryRow(_ e: ShenkuoEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(e.desc?.isEmpty == false ? e.desc! : (e.aweme_id ?? "?"))
                    .font(.subheadline.weight(.medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let d = e.digg {
                    Label(diggText(d), systemImage: "heart.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.pink)
                }
            }
            HStack(spacing: 6) {
                stageChip("下载", e.status?["download"])
                stageChip("转写", e.status?["transcribe"])
                stageChip("抠图", e.status?["cutout"])
                stageChip("评论", e.status?["comments"])
                Spacer()
                if let f = e.frames, !f.isEmpty {
                    Text("帧 \(f.count) · 抠 \(e.cutouts?.count ?? 0)")
                        .font(.caption2).foregroundStyle(Color.ctInk.opacity(0.4))
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 工序状态点:ok/cached=绿,error*/failed/no_url=红,没跑到=灰。
    private func stageChip(_ label: String, _ status: String?) -> some View {
        let (color, icon): (Color, String) = {
            guard let s = status else { return (Color.ctInk.opacity(0.3), "minus.circle") }
            if s == "ok" || s == "cached" { return (.green, "checkmark.circle.fill") }
            return (.red, "xmark.circle.fill")
        }()
        return HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9))
            Text(label).font(.caption2)
        }
        .foregroundStyle(color)
    }

    private func diggText(_ n: Int) -> String {
        n >= 10000 ? String(format: "%.1fw", Double(n) / 10000) : "\(n)"
    }
}

// MARK: - 卧龙:编排战报(产出条数 + 日志末尾)

struct WolongReportPanel: View {
    let result: WolongResult
    let agent: AgentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("编排战报").font(.headline)
                Spacer()
                tagChip("产出 \(result.count ?? 0) 条", agent.accent, icon: "shippingbox.fill")
            }
            Text("成片在下方「待验收清单」目录里逐条审看")
                .font(.footnote).foregroundStyle(Color.ctInk.opacity(0.55))
            if let tail = result.tail, !tail.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.ctInk.opacity(0.6))
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("编排日志末尾", systemImage: "terminal")
                        .font(.subheadline.weight(.medium))
                }
                .tint(Color.ctInk.opacity(0.5))
            }
        }
        .resultCard()
    }
}

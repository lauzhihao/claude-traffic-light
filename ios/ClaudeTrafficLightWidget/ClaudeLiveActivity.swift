import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

struct ClaudeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClaudeAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Circle()
                        .fill(stateColor(context.state.state))
                        .frame(width: 36, height: 36)
                        .shadow(color: stateColor(context.state.state), radius: 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Code")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                        Text(stateLabel(context.state.state))
                            .font(.caption2)
                            .foregroundStyle(stateColor(context.state.state))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrafficStack(state: context.state.state, compact: true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    BottomView(state: context.state)
                }
            } compactLeading: {
                Circle()
                    .fill(stateColor(context.state.state))
                    .frame(width: 14, height: 14)
            } compactTrailing: {
                Text(stateLabel(context.state.state))
                    .font(.caption2.bold())
                    .foregroundStyle(stateColor(context.state.state))
            } minimal: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(stateColor(context.state.state))
            }
            .keylineTint(stateColor(context.state.state))
        }
    }
}

// 灵动岛展开后底部区：Y 状态显示批准按钮；其他状态显示配额
struct BottomView: View {
    let state: ClaudeAttributes.ContentState

    var body: some View {
        if state.state == "Y", let pending = state.pending {
            ApprovalButtons(pending: pending)
        } else if let quota = state.quota {
            QuotaRow(quota: quota)
        } else {
            EmptyView()
        }
    }
}

struct ApprovalButtons: View {
    let pending: ClaudeAttributes.ContentState.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview = pending.preview, !preview.isEmpty {
                Text("\(pending.tool): \(preview)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text(pending.tool)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
            HStack(spacing: 8) {
                Button(intent: ApproveIntent(requestId: pending.id)) {
                    Label("批准", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                }
                .tint(.green)
                .buttonStyle(.borderedProminent)

                Button(intent: DenyIntent(requestId: pending.id)) {
                    Label("拒绝", systemImage: "xmark.circle.fill")
                        .font(.caption.bold())
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct QuotaRow: View {
    let quota: ClaudeAttributes.ContentState.Quota

    var body: some View {
        HStack {
            Label(fmt(quota.tokens5h), systemImage: "clock")
                .font(.caption2)
            Spacer()
            Label(fmt(quota.tokens7d), systemImage: "calendar")
                .font(.caption2)
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    func fmt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

struct TrafficStack: View {
    let state: String
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 3 : 6) {
            Bulb(color: .red, on: state == "R", size: compact ? 10 : 18)
            Bulb(color: .yellow, on: state == "Y", size: compact ? 10 : 18)
            Bulb(color: .green, on: state == "G", size: compact ? 10 : 18)
        }
        .padding(compact ? 4 : 8)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 10))
    }
}

struct Bulb: View {
    let color: Color
    let on: Bool
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(on ? color : color.opacity(0.18))
            .frame(width: size, height: size)
            .shadow(color: on ? color : .clear, radius: on ? size / 2.5 : 0)
    }
}

struct LockScreenView: View {
    let state: ClaudeAttributes.ContentState

    var body: some View {
        HStack(spacing: 16) {
            TrafficStack(state: state.state, compact: false)
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Code")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(stateLabel(state.state))
                    .font(.subheadline)
                    .foregroundStyle(stateColor(state.state))
                if let quota = state.quota {
                    QuotaRow(quota: quota).padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding()
        .overlay(alignment: .bottom) {
            if state.state == "Y", let pending = state.pending {
                ApprovalButtons(pending: pending)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }
}

func stateColor(_ s: String) -> Color {
    switch s {
    case "R": return .red
    case "Y": return .yellow
    case "G": return .green
    default: return .gray
    }
}

func stateLabel(_ s: String) -> String {
    switch s {
    case "R": return "thinking"
    case "Y": return "waiting"
    case "G": return "ready"
    default: return "—"
    }
}

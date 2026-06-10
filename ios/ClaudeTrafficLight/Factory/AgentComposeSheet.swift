import SwiftUI
import UIKit

// 通用新建任务表单：按 GET /commands/{cmd}/schema 动态渲染字段。
// 后端约定 params 是动态的——字段说明书运行时取，前端不硬编码各命令的字段；
// 所以新 agent / 字段变更零代码适配。柳永保留手工定制的 LiuyongComposeSheet(语音下选题)，
// 其余 agent 都走这里。必填字段平铺，选填收进「更多选项」，保持表单第一眼极简。

struct AgentComposeSheet: View {
    let agent: AgentInfo

    @Environment(\.dismiss) private var dismiss
    @State private var schema: CommandSchema?
    @State private var loadError: String?
    @State private var text: [String: String] = [:]   // 文本类字段输入暂存(含 int/float/enum/string[])
    @State private var flags: [String: Bool] = [:]    // bool 字段
    @State private var submitting = false
    @State private var errText: String?

    private var fields: [NofField] { schema?.fields ?? [] }
    private var requiredFields: [NofField] { fields.filter(\.isRequired) }
    private var optionalFields: [NofField] { fields.filter { !$0.isRequired } }

    private var canSubmit: Bool {
        schema != nil && !submitting && requiredFields.allSatisfy {
            $0.type == "bool" || !(text[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if schema != nil {
                    form
                } else if let loadError {
                    ContentUnavailableView {
                        Label("拿不到表单", systemImage: "wifi.slash")
                    } description: {
                        Text(loadError).font(.footnote)
                    }
                } else {
                    ProgressView("读取表单…")
                }
            }
            .navigationTitle("交给\(agent.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发起") { Task { await submit() } }
                        .disabled(!canSubmit)
                }
            }
        }
        .task { await loadSchema() }
    }

    // MARK: - 表单

    private var form: some View {
        Form {
            if let summary = schema?.summary, !summary.isEmpty {
                Section { Text(summary).font(.footnote).foregroundStyle(.secondary) }
            }
            if !requiredFields.isEmpty {
                Section("必填") { ForEach(requiredFields) { fieldRow($0) } }
            }
            if !optionalFields.isEmpty {
                Section {
                    DisclosureGroup("更多选项（选填）") {
                        ForEach(optionalFields) { fieldRow($0) }
                    }
                }
            }
            if let errText {
                Section { Text(errText).foregroundStyle(.red).font(.footnote) }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ f: NofField) -> some View {
        switch f.type {
        case "bool":
            Toggle(f.label, isOn: boolBinding(f))
        case "enum":
            Picker(f.label, selection: textBinding(f)) {
                ForEach(f.enum ?? [], id: \.self) { Text($0).tag($0) }
            }
        case "text":
            labeled(f) {
                TextField(f.help ?? "", text: textBinding(f), axis: .vertical)
                    .lineLimit(2...6)
            }
        default:   // string / int / float / string[]
            labeled(f) {
                HStack {
                    TextField(placeholder(f), text: textBinding(f))
                        .keyboardType(f.type == "int" ? .numberPad
                                      : f.type == "float" ? .decimalPad : .default)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    // 路径/ID 类参数基本靠粘贴,给个就手的按钮
                    if f.type == "string" || f.type == "string[]" {
                        Button {
                            if let s = UIPasteboard.general.string { text[f.name] = s }
                        } label: {
                            Image(systemName: "doc.on.clipboard").font(.footnote)
                        }
                        .buttonStyle(.borderless)
                        .tint(agent.accent)
                    }
                }
            }
        }
    }

    private func labeled(_ f: NofField, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(f.label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func placeholder(_ f: NofField) -> String {
        if f.type == "string[]" {
            return f.help.map { "\($0)（逗号分隔）" } ?? "逗号分隔多个值"
        }
        return f.help ?? ""
    }

    private func textBinding(_ f: NofField) -> Binding<String> {
        Binding(get: { text[f.name] ?? "" }, set: { text[f.name] = $0 })
    }

    private func boolBinding(_ f: NofField) -> Binding<Bool> {
        Binding(get: { flags[f.name] ?? false }, set: { flags[f.name] = $0 })
    }

    // MARK: - 行为

    private func loadSchema() async {
        do {
            let s = try await NofClient().schema(agent.cmd)
            // 预填默认值;enum 没默认就选第一项,避免 Picker 空选中态
            for f in s.fields {
                if f.type == "bool" {
                    flags[f.name] = f.default?.boolValue ?? false
                } else if let d = f.default?.display, !d.isEmpty {
                    text[f.name] = d
                } else if f.type == "enum", let first = f.enum?.first {
                    text[f.name] = first
                }
            }
            schema = s
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// 按字段 type 把文本输入转回原生类型;空值不发,让后端用 run() 的默认值。
    private func submit() async {
        submitting = true
        errText = nil
        var params: [String: Any] = [:]
        for f in fields {
            if f.type == "bool" {
                if let b = flags[f.name] { params[f.name] = b }
                continue
            }
            let raw = (text[f.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            switch f.type {
            case "int":      params[f.name] = Int(raw) ?? raw
            case "float":    params[f.name] = Double(raw) ?? raw
            case "string[]": params[f.name] = raw.split(separator: ",")
                                                 .map { $0.trimmingCharacters(in: .whitespaces) }
                                                 .filter { !$0.isEmpty }
            default:         params[f.name] = raw
            }
        }
        do {
            _ = try await NofClient().createTask(cmd: agent.cmd, params: params)
            dismiss()
        } catch {
            errText = error.localizedDescription
            submitting = false
        }
    }
}

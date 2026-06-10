import Foundation
import SwiftUI

// ncds-opus-studio server 客户端。LAN 直连。
// 默认地址用 mDNS/Bonjour 主机名(liuzhihao-mbp.local)而非 IP——Mac 换 WiFi/换地方
// 不用改;只要手机和 Mac 在同一网段(同 WiFi 或手机热点)就能解析。
// 个别路由器开了 AP 隔离/禁多播会解析不到,届时在「设置」里临时填 IP 兜底。

enum NofConfig {
    static let baseURLKey = "nof_base_url"
    static let defaultBaseURL = "http://liuzhihao-mbp.local:8810"

    static var baseURL: String {
        let v = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
        return v.isEmpty ? defaultBaseURL : v
    }
}

enum NofError: LocalizedError {
    case badURL(String)
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "地址非法：\(s)"
        case .http(let code, let body): return "HTTP \(code)：\(body)"
        case .decode(let s): return "解析失败：\(s)"
        }
    }
}

struct NofClient {
    let baseURL: String

    init(baseURL: String = NofConfig.baseURL) {
        // 去掉末尾斜杠，避免拼出 //tasks
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    private func makeURL(_ path: String) throws -> URL {
        guard let u = URL(string: baseURL + path) else { throw NofError.badURL(baseURL + path) }
        return u
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            throw NofError.decode("\(error) | body=\(body.prefix(300))")
        }
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(from: try makeURL(path))
        try Self.ensureOK(resp, data)
        return try decode(T.self, from: data)
    }

    private static func ensureOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NofError.http(http.statusCode, String(body.prefix(300)))
        }
    }

    // MARK: - Commands / Schema

    func listCommands() async throws -> [NofCommand] {
        try await get("/commands", as: CommandsResponse.self).commands
    }

    func schema(_ cmd: String) async throws -> CommandSchema {
        try await get("/commands/\(cmd)/schema", as: CommandSchema.self)
    }

    // MARK: - Tasks

    func createTask(cmd: String, params: [String: Any]) async throws -> String {
        var req = URLRequest(url: try makeURL("/tasks"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["cmd": cmd, "params": params])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.ensureOK(resp, data)
        return try decode(TaskCreateResponse.self, from: data).task_id
    }

    func listTasks() async throws -> [TaskMeta] {
        try await get("/tasks", as: [TaskMeta].self)
    }

    func task(_ id: String) async throws -> TaskDetail {
        try await get("/tasks/\(id)", as: TaskDetail.self)
    }

    /// 柳永专属详情：result.drafts 含稿件全文 + 两道质检，一次拿全。
    func liuyongTask(_ id: String) async throws -> TaskDetailLiuyong {
        try await get("/tasks/\(id)", as: TaskDetailLiuyong.self)
    }

    /// 泛型详情：result 按 R 强类型解(解不动置 nil)，其余 agent 专属页一次拿全。
    func typedTask<R: Decodable>(_ id: String, as type: R.Type) async throws -> TaskDetailTyped<R> {
        try await get("/tasks/\(id)", as: TaskDetailTyped<R>.self)
    }

    @discardableResult
    func review(_ id: String, decision: String, note: String?) async throws -> NofReview {
        var req = URLRequest(url: try makeURL("/tasks/\(id)/review"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["decision": decision]
        if let note, !note.isEmpty { body["note"] = note }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.ensureOK(resp, data)
        return try decode(NofReview.self, from: data)
    }

    func dirListing(_ url: String) async throws -> DirListing {
        try await get(url, as: DirListing.self)
    }

    /// 绝对化产物 URL（artifact.url 是相对 `/artifacts/...`）供 AsyncImage / AVPlayer 直用。
    func absoluteURL(_ relative: String) -> URL? {
        if relative.hasPrefix("http") { return URL(string: relative) }
        return URL(string: baseURL + relative)
    }

    // MARK: - SSE 进度流
    // Swift 无原生 EventSource：用 URLSession.bytes 按行读 text/event-stream，
    // 取 `data:` 行，解析成 TaskEvent；收到 `[DONE]` 结束。

    func events(_ id: String) -> AsyncThrowingStream<TaskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: try makeURL("/tasks/\(id)/events"))
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 3600  // 长任务进度间隔可能 >60s，放宽
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw NofError.http(http.statusCode, "events stream")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let d = payload.data(using: .utf8),
                           let ev = try? JSONDecoder().decode(TaskEvent.self, from: d) {
                            continuation.yield(ev)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

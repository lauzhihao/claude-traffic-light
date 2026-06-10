import Foundation

// ncds-opus-studio HTTP API 的 Codable 模型。字段对照 docs/FRONTEND-API.md：
//   GET  /commands               -> { commands: [NofCommand] }
//   GET  /commands/{cmd}/schema  -> CommandSchema
//   POST /tasks                  -> TaskCreateResponse
//   GET  /tasks                  -> [TaskMeta]
//   GET  /tasks/{id}             -> TaskDetail（含 artifacts + review）
//   GET  /tasks/{id}/events      -> SSE，每条是 TaskEvent 或 "[DONE]"
//   POST /tasks/{id}/review      -> NofReview

/// 任意标量值（字段 default 可能是 string/int/float/bool）。只取展示文本即可。
enum JSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    /// 预填表单用的文本表示。
    var display: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        }
    }

    var boolValue: Bool {
        if case .bool(let b) = self { return b }
        return false
    }

    /// 还原成 JSONSerialization 可用的原生值(重新发起任务时把 params 原样回填)。
    var anyValue: Any? {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return nil
        }
    }
}

struct NofCommand: Codable, Identifiable {
    let name: String
    let label: String
    let group: String
    let summary: String
    var id: String { name }
}

struct CommandsResponse: Codable {
    let commands: [NofCommand]
}

/// 一个表单字段。type ∈ string/text/int/float/bool/string[]/enum。
struct NofField: Codable, Identifiable {
    let name: String
    let label: String
    let type: String
    let required: Bool?
    let `default`: JSONValue?
    let `enum`: [String]?
    let help: String?
    var id: String { name }

    var isRequired: Bool { required ?? false }
}

struct CommandSchema: Codable {
    let cmd: String?
    let label: String?
    let group: String?
    let summary: String?
    let fields: [NofField]
}

struct TaskCreateResponse: Codable {
    let task_id: String
    let status: String
}

/// 可审看产物。kind ∈ script/audio/video/image/data/dir/text/file。
struct NofArtifact: Codable, Identifiable {
    let label: String
    let kind: String
    let url: String
    let path: String?
    var id: String { url }
}

struct NofReview: Codable {
    let decision: String          // approved / rejected
    let note: String?
    let reviewed_at: String?
}

/// GET /tasks 列表项（收件箱）。decision 由后端回填，未决为 nil。
/// params 原样带回（如柳永的 topic），做任务卡标题用。
struct TaskMeta: Codable, Identifiable {
    let task_id: String
    let cmd: String
    let status: String
    let created_at: String?
    let decision: String?
    let params: [String: JSONValue]?
    var id: String { task_id }

    /// 卡片标题：按各 agent 的「主参数」优先取，路径类只留文件名；都没有才兜底首个参数。
    var titleGuess: String {
        for key in ["topic", "author", "aweme", "benchmark_path", "script_path", "job_dir", "html_url", "prompt"] {
            guard let v = params?[key]?.display, !v.isEmpty else { continue }
            return key.hasSuffix("_path") || key.hasSuffix("_dir")
                ? URL(fileURLWithPath: v).lastPathComponent : v
        }
        if let c = params?["count"]?.display, !c.isEmpty { return "本轮产出 \(c) 条" }   // 卧龙
        if let p = params?.values.first?.display, !p.isEmpty { return p }
        return "(无参数)"
    }

    /// params 还原成 [String: Any](失败任务「重新发起」用)。
    var paramsAny: [String: Any] {
        (params ?? [:]).compactMapValues { $0.anyValue }
    }
}

/// GET /tasks/{id} 详情。result 是任意 dict，UI 只用 artifacts/review，故不解。
struct TaskDetail: Codable {
    let task_id: String
    let cmd: String
    let status: String
    let error: String?
    let artifacts: [NofArtifact]?
    let review: NofReview?
}

/// SSE 信封里的一条事件。type ∈ progress/done/error。
struct TaskEvent: Codable {
    let type: String
    let ts: Int?
    let text: String?
    let error: String?
}

/// 目录列举（GET /artifacts/dir/...）。
struct DirEntry: Codable, Identifiable {
    let name: String
    let is_dir: Bool
    let size: Int?
    let kind: String
    let url: String?
    var id: String { name }
}

struct DirListing: Codable {
    let relpath: String
    let entries: [DirEntry]
}

// MARK: - 柳永专属：result.drafts 里直接带稿件全文 + 两道质检，一次详情请求全拿到

struct TaskDetailLiuyong: Codable {
    let status: String
    let error: String?
    let review: NofReview?
    let result: LiuyongResult?
}

struct LiuyongResult: Codable {
    let drafts: [LiuyongDraft]?
    let job_id: String?
    let deliverables_dir: String?
}

struct LiuyongDraft: Codable {
    let model: String?
    let text: String?
    let qc: AiTasteQC?         // AI 味扫描
    let qc_rubric: RubricQC?   // opus rubric 打分
}

/// AI 味扫描：verdict=fail 表示曾被打回重写。density/hard 是命中的句式。
struct AiTasteQC: Codable {
    let verdict: String?
    let summary: String?
    let density: [QCHit]?
    let hard: [QCHit]?
}

struct QCHit: Codable {
    let rule: String?
    let count: Int?
    let threshold: Int?
    let severity: String?
    let samples: [String]?
}

/// opus rubric：5 维各 /10，total /50，grade=优秀/良好/需重修；不可用时 available=false。
struct RubricQC: Codable {
    let available: Bool?
    let dims: [String: Int]?
    let total: Int?
    let grade: String?
    let issues: [String]?
    let skipped: String?
}

// MARK: - 泛型详情信封：同 GET /tasks/{id}，result 按各 agent 形态强类型解

/// result 解不动（后端形态漂移）时静默置 nil——页面退化成「只剩产物区」，不整页报错。
struct TaskDetailTyped<R: Decodable>: Decodable {
    let status: String
    let error: String?
    let artifacts: [NofArtifact]?
    let review: NofReview?
    let result: R?

    private enum K: String, CodingKey { case status, error, artifacts, review, result }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        status = try c.decode(String.self, forKey: .status)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        artifacts = try c.decodeIfPresent([NofArtifact].self, forKey: .artifacts)
        review = try c.decodeIfPresent(NofReview.self, forKey: .review)
        result = try? c.decodeIfPresent(R.self, forKey: .result)
    }
}

// MARK: - 鬼谷子：result.topics 选题库

struct GuiguziResult: Codable {
    let topics: [GuiguziTopic]?
    let out: String?
}

/// 一条选题。potential 是 1-10 爆款潜力分(模型生成,用 Double 容错小数)。
struct GuiguziTopic: Codable {
    let title: String?
    let motif: String?
    let source: String?
    let why: String?
    let potential: Double?
}

// MARK: - 吴道子：beats 分镜 + 不丢句质检

struct WudaoziResult: Codable {
    let job_id: String?
    let out_dir: String?
    let beats: [WudaoziBeat]?
    let storyboard_path: String?
    let qc: WudaoziQC?
}

/// 一句分镜：zh 台词必有；figure/icons/motion 是视觉选用。
struct WudaoziBeat: Codable {
    let zh: String?
    let figure: String?
    let icons: [String]?
    let motion: String?
    let title: String?
    let tag: String?
    let kind: String?
}

/// 不丢句硬校验(ratio=字符覆盖率) + 软质检 warnings。
struct WudaoziQC: Codable {
    let verdict: String?
    let ratio: Double?
    let warnings: [String]?
}

// MARK: - 伯牙：result = audio_plan(声音床方案)

struct BoyaResult: Codable {
    let job: String?
    let scene: String?
    let voice: BoyaVoice?
    let bgm: BoyaBGM?          // 库内无可用 BGM 时为 null
    let sfx: [BoyaSfxCue]?
    let audition: BoyaAudition?
}

struct BoyaVoice: Codable {
    let clips: Int?
    let duration_s: Double?
}

struct BoyaBGM: Codable {
    let file: String?
    let volume_db: Double?
    let reason: String?
}

struct BoyaSfxCue: Codable {
    let beat: Int?
    let kind: String?
    let cue: String?
    let time_s: Double?
    let file: String?
    let reason: String?
}

/// 听感质检：verdict ∈ ok/warn，notes 是逐条提醒(语速过快/过慢等)。
struct BoyaAudition: Codable {
    let verdict: String?
    let voice_total_s: Double?
    let notes: [String]?
}

// MARK: - 沈括：采集成果(作者目录 + 逐条采集清单)

struct ShenkuoResult: Codable {
    let author_dir: String?
    let all_posts: Int?         // 拉到的作品总数(单条模式没有)
    let collected: [ShenkuoEntry]?
    let snapshots: Int?         // refresh-only 模式的指标快照数
}

/// 一条采集结果。status 是各工序的状态字(download/transcribe/cutout/comments -> ok/cached/error:*)。
struct ShenkuoEntry: Codable {
    let aweme_id: String?
    let desc: String?
    let digg: Int?
    let status: [String: String]?
    let frames: [String]?
    let cutouts: [String]?
}

// MARK: - 卧龙：编排战报

struct WolongResult: Codable {
    let count: Int?
    let review_dir: String?
    let tail: [String]?         // 编排日志末 20 行
}

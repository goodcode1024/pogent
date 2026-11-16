import Foundation

// MARK: - 风险等级

/// 风险等级决定审批策略：越高的等级越不可能被自动放行。
enum RiskLevel: Int, Codable, Comparable, Sendable, CaseIterable {
    case safe = 0          // 读日历、读文件、截图
    case sensitive = 1     // 发消息、改日程、写文件
    case destructive = 2   // 删除、清空、覆盖
    case financial = 3     // 付款、转账、Wallet

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .safe: "安全"
        case .sensitive: "敏感"
        case .destructive: "破坏性"
        case .financial: "资金"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield"
        case .sensitive: "exclamationmark.shield"
        case .destructive: "trash"
        case .financial: "creditcard"
        }
    }

    /// 资金类操作永远人工确认，任何策略都不能自动放行。
    var alwaysAsksHuman: Bool { self == .financial }
}

// MARK: - 执行面

/// pogent 的三层执行面：能调 API 就不跑命令，能跑命令就不点界面。
enum ExecutionSurface: String, Codable, Sendable, CaseIterable {
    case native   // EventKit / HealthKit / PhotoKit / 文件 / URLSession
    case shell    // 内置 bash / node / python / git / ffmpeg
    case ui       // 读屏 + 点按 + 输入（原来的 Poki 路径）

    var title: String {
        switch self {
        case .native: "系统能力"
        case .shell: "本机运行时"
        case .ui: "界面操控"
        }
    }

    /// 越低越优先：可靠、快、便宜、可回放。
    var priority: Int {
        switch self {
        case .native: 0
        case .shell: 1
        case .ui: 2
        }
    }
}

// MARK: - 工具定义

struct ToolDefinition: Sendable, Identifiable {
    let name: String
    let summary: String
    let surface: ExecutionSurface
    let risk: RiskLevel
    /// JSON Schema，直接交给模型。
    let parameters: JSONValue
    /// 是否必须在前台（界面操控、拍照、发消息面板）。
    let requiresForeground: Bool
    /// 是否允许在后台任务里跑。
    let allowsBackground: Bool

    var id: String { name }

    init(
        name: String,
        summary: String,
        surface: ExecutionSurface,
        risk: RiskLevel,
        parameters: JSONValue = .object(["type": "object", "properties": .object([:])]),
        requiresForeground: Bool = false,
        allowsBackground: Bool? = nil
    ) {
        self.name = name
        self.summary = summary
        self.surface = surface
        self.risk = risk
        self.parameters = parameters
        self.requiresForeground = requiresForeground
        self.allowsBackground = allowsBackground ?? !requiresForeground
    }

    var modelDescription: String {
        "[\(surface.rawValue)] \(name) — \(summary)（风险：\(risk.title)）"
    }
}

// MARK: - 调用与结果

struct ToolInvocation: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let arguments: JSONValue

    init(id: String = UUID().uuidString, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

struct ToolOutcome: Sendable {
    enum Status: String, Sendable {
        case ok
        case failed
        case denied
        case needsHuman
    }

    var status: Status
    var summary: String
    var payload: JSONValue
    /// 给模型看的内容（截断后的可读文本）。
    var modelText: String

    static func ok(_ summary: String, payload: JSONValue = .null, modelText: String? = nil) -> ToolOutcome {
        ToolOutcome(status: .ok, summary: summary, payload: payload, modelText: modelText ?? summary)
    }

    static func failed(_ reason: String) -> ToolOutcome {
        ToolOutcome(status: .failed, summary: reason, payload: .object(["error": .string(reason)]), modelText: "失败：\(reason)")
    }

    static func denied(_ reason: String) -> ToolOutcome {
        ToolOutcome(status: .denied, summary: reason, payload: .object(["denied": .string(reason)]), modelText: "被拒绝：\(reason)")
    }

    static func needsHuman(_ reason: String, kind: String) -> ToolOutcome {
        ToolOutcome(
            status: .needsHuman,
            summary: reason,
            payload: .object(["handoff": .string(kind)]),
            modelText: "需要本人接管（\(kind)）：\(reason)"
        )
    }

    var isSuccess: Bool { status == .ok }
}

// MARK: - 工具上下文

/// 工具拿到的运行时上下文。审批走闭包，工具不直接碰 UI。
struct ToolContext {
    var runID: String
    var conversationID: String
    var workspace: URL
    var originApp: String?
    var requestApproval: (ApprovalRequest) async -> ApprovalDecision
    var recordActivity: (String) -> Void
}

// MARK: - 协议

@MainActor
protocol AgentTool: AnyObject {
    var definition: ToolDefinition { get }
    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome
}

// MARK: - 便捷构造

// 参数 schema 的便捷构造。挂在 JSONValue 上，因为调用点是
// `parameters: .jsonSchema(...)`，上下文类型就是 JSONValue。
extension JSONValue {
    static func jsonSchema(
        properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false)
        ])
    }

    static func stringParam(_ description: String) -> JSONValue {
        .object(["type": "string", "description": .string(description)])
    }

    static func numberParam(_ description: String) -> JSONValue {
        .object(["type": "number", "description": .string(description)])
    }

    static func boolParam(_ description: String) -> JSONValue {
        .object(["type": "boolean", "description": .string(description)])
    }

    static func arrayParam(_ description: String, itemType: String = "string") -> JSONValue {
        .object([
            "type": "array",
            "description": .string(description),
            "items": .object(["type": .string(itemType)])
        ])
    }
}

import Foundation
import SwiftData

// MARK: - 会话

@Model
final class Conversation {
    @Attribute(.unique) var id: String
    var title: String
    var kindRaw: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var botID: String?
    var remoteHost: String?
    var lastText: String
    var isArchived: Bool = false
    var isMuted: Bool = false

    init(
        id: String = UUID().uuidString,
        title: String,
        kind: ConversationKind = .local,
        botID: String? = nil,
        remoteHost: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kindRaw = kind.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isPinned = false
        self.botID = botID
        self.remoteHost = remoteHost
        self.lastText = ""
    }

    var kind: ConversationKind {
        get { ConversationKind(rawValue: kindRaw) ?? .local }
        set { kindRaw = newValue.rawValue }
    }
}

enum ConversationKind: String, Codable, CaseIterable, Sendable {
    case local      // 本机会话
    case bot        // Bot 私聊 / 群聊
    case remote     // 远程机器上的 Codex / Claude Code / DSH
    case voice      // 语音通话
}

// MARK: - 消息

@Model
final class ChatMessage {
    @Attribute(.unique) var id: String
    var conversationID: String
    var roleRaw: String
    var text: String
    var createdAt: Date
    var runID: String?
    var attachmentNames: [String]

    init(
        id: String = UUID().uuidString,
        conversationID: String,
        role: MessageRole,
        text: String,
        runID: String? = nil,
        attachmentNames: [String] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = Date()
        self.runID = runID
        self.attachmentNames = attachmentNames
    }

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .assistant }
        set { roleRaw = newValue.rawValue }
    }
}

enum MessageRole: String, Codable, Sendable {
    case user, assistant, system, tool
}

// MARK: - 运行与步骤

@Model
final class RunRecord {
    @Attribute(.unique) var id: String
    var conversationID: String
    var goal: String
    var stateRaw: String
    var startedAt: Date
    var endedAt: Date?
    var stepCount: Int
    var tokenEstimate: Int

    init(id: String = UUID().uuidString, conversationID: String, goal: String) {
        self.id = id
        self.conversationID = conversationID
        self.goal = goal
        self.stateRaw = RunState.running.rawValue
        self.startedAt = Date()
        self.stepCount = 0
        self.tokenEstimate = 0
    }

    var state: RunState {
        get { RunState(rawValue: stateRaw) ?? .running }
        set { stateRaw = newValue.rawValue }
    }
}

enum RunState: String, Codable, Sendable {
    case running, waitingApproval, done, failed, cancelled
}

@Model
final class StepRecord {
    @Attribute(.unique) var id: String
    var runID: String
    var index: Int
    var title: String
    var detail: String
    var surfaceRaw: String
    var riskRaw: Int
    var statusRaw: String
    var startedAt: Date
    var duration: TimeInterval

    init(
        id: String = UUID().uuidString,
        runID: String,
        index: Int,
        title: String,
        detail: String,
        surface: ExecutionSurface,
        risk: RiskLevel,
        status: StepStatus = .running
    ) {
        self.id = id
        self.runID = runID
        self.index = index
        self.title = title
        self.detail = detail
        self.surfaceRaw = surface.rawValue
        self.riskRaw = risk.rawValue
        self.statusRaw = status.rawValue
        self.startedAt = Date()
        self.duration = 0
    }

    var surface: ExecutionSurface { ExecutionSurface(rawValue: surfaceRaw) ?? .native }
    var risk: RiskLevel { RiskLevel(rawValue: riskRaw) ?? .safe }
    var status: StepStatus {
        get { StepStatus(rawValue: statusRaw) ?? .running }
        set { statusRaw = newValue.rawValue }
    }
}

enum StepStatus: String, Codable, Sendable {
    case running, done, failed, denied, skipped
}

// MARK: - Bot

@Model
final class BotProfile {
    @Attribute(.unique) var id: String
    var name: String
    var symbol: String
    var colorHex: String
    var persona: String
    var workingDirectory: String
    var memory: String
    var schedule: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        symbol: String = "fish.fill",
        colorHex: String = "#5EEAD4",
        persona: String = "",
        workingDirectory: String = "",
        memory: String = "",
        schedule: String = ""
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.persona = persona
        self.workingDirectory = workingDirectory
        self.memory = memory
        self.schedule = schedule
        self.createdAt = Date()
    }
}

// MARK: - 技能 / 插件

@Model
final class SkillRecord {
    @Attribute(.unique) var id: String
    var name: String
    var summary: String
    var goalTemplate: String
    var stepsJSON: String
    var createdAt: Date
    var uses: Int

    init(id: String = UUID().uuidString, name: String, summary: String, goalTemplate: String, stepsJSON: String) {
        self.id = id
        self.name = name
        self.summary = summary
        self.goalTemplate = goalTemplate
        self.stepsJSON = stepsJSON
        self.createdAt = Date()
        self.uses = 0
    }
}

@Model
final class PluginRecord {
    @Attribute(.unique) var id: String
    var name: String
    var version: String
    var source: String
    var summary: String
    var isEnabled: Bool
    var installedAt: Date
    var manifestJSON: String

    init(id: String = UUID().uuidString, name: String, version: String, source: String, summary: String, manifestJSON: String) {
        self.id = id
        self.name = name
        self.version = version
        self.source = source
        self.summary = summary
        self.isEnabled = true
        self.installedAt = Date()
        self.manifestJSON = manifestJSON
    }
}

// MARK: - 容器

// MARK: - 长期记忆 / 连接器 / 能力开关

/// 跨会话长期记忆。模型可以主动写入，也可以在设置里手动管理。
@Model
final class MemoryRecord {
    @Attribute(.unique) var id: String
    var text: String
    var kindRaw: String
    var createdAt: Date
    var lastUsedAt: Date
    var uses: Int

    init(id: String = UUID().uuidString, text: String, kind: MemoryKind = .fact) {
        self.id = id
        self.text = text
        self.kindRaw = kind.rawValue
        self.createdAt = Date()
        self.lastUsedAt = Date()
        self.uses = 0
    }

    var kind: MemoryKind {
        get { MemoryKind(rawValue: kindRaw) ?? .fact }
        set { kindRaw = newValue.rawValue }
    }
}

enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case fact       // 事实：我住在杭州
    case preference // 偏好：回答短一点
    case contact    // 人物：老婆叫小美
    case routine    // 习惯：每周一早上做周报
    case secret     // 只在本机保存的敏感备注

    var title: String {
        switch self {
        case .fact: "事实"
        case .preference: "偏好"
        case .contact: "人物"
        case .routine: "习惯"
        case .secret: "私密"
        }
    }
}

/// 外部服务连接器。凭证存在 Keychain，表里只放元信息。
@Model
final class ConnectorRecord {
    @Attribute(.unique) var id: String
    var kindRaw: String
    var displayName: String
    var account: String
    var isEnabled: Bool
    var createdAt: Date
    var lastUsedAt: Date?
    var configJSON: String

    init(
        id: String = UUID().uuidString,
        kind: ConnectorKind,
        displayName: String,
        account: String = "",
        configJSON: String = "{}"
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.displayName = displayName
        self.account = account
        self.isEnabled = true
        self.createdAt = Date()
        self.configJSON = configJSON
    }

    var kind: ConnectorKind {
        get { ConnectorKind(rawValue: kindRaw) ?? .github }
        set { kindRaw = newValue.rawValue }
    }
}

enum ConnectorKind: String, Codable, CaseIterable, Sendable {
    case github, notion, webhook, rss, openaiCompatible

    var title: String {
        switch self {
        case .github: "GitHub"
        case .notion: "Notion"
        case .webhook: "Webhook"
        case .rss: "RSS"
        case .openaiCompatible: "自定义模型"
        }
    }

    var symbol: String {
        switch self {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .notion: "doc.text"
        case .webhook: "arrow.up.right.circle"
        case .rss: "dot.radiowaves.left.and.right"
        case .openaiCompatible: "cpu"
        }
    }

    /// 需要用户填的字段标题。
    var credentialLabel: String {
        switch self {
        case .github: "Personal Access Token"
        case .notion: "Integration Token"
        case .webhook: "签名密钥（可选）"
        case .rss: "无"
        case .openaiCompatible: "API Key"
        }
    }
}

/// 本机能力的一次性开关状态。用户关掉后，工具直接拒绝。
@Model
final class CapabilityRecord {
    @Attribute(.unique) var id: String
    var isEnabled: Bool
    var grantedAt: Date?
    var lastUsedAt: Date?

    init(id: String, isEnabled: Bool = false) {
        self.id = id
        self.isEnabled = isEnabled
    }
}

// MARK: - 容器

enum PogentStore {
    static let schema = Schema([
        Conversation.self,
        ChatMessage.self,
        RunRecord.self,
        StepRecord.self,
        BotProfile.self,
        SkillRecord.self,
        PluginRecord.self,
        MemoryRecord.self,
        ConnectorRecord.self,
        CapabilityRecord.self
    ])

    static func container(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("无法打开本地数据库：\(error)")
        }
    }
}

// MARK: - 便捷查询

extension ChatMessage {
    static func history(for conversationID: String, in context: ModelContext, limit: Int = 60) -> [ChatMessage] {
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }
}

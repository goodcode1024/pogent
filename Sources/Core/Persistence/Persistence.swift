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

enum PogentStore {
    static let schema = Schema([
        Conversation.self,
        ChatMessage.self,
        RunRecord.self,
        StepRecord.self,
        BotProfile.self,
        SkillRecord.self,
        PluginRecord.self
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

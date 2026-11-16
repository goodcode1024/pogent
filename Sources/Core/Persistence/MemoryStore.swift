import Foundation
import SwiftData
import Observation

/// 跨会话记忆。模型主动写入，用户在设置里可以逐条删除。
@MainActor
@Observable
final class MemoryStore {
    private let context: ModelContext
    private(set) var items: [MemoryRecord] = []

    init(context: ModelContext) {
        self.context = context
        reload()
    }

    func reload() {
        let descriptor = FetchDescriptor<MemoryRecord>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        items = (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func add(_ text: String, kind: MemoryKind = .fact) -> MemoryRecord {
        // 同样内容不重复存。
        if let existing = items.first(where: { $0.text == text }) {
            existing.lastUsedAt = Date()
            existing.uses += 1
            try? context.save()
            return existing
        }
        let record = MemoryRecord(text: text, kind: kind)
        context.insert(record)
        try? context.save()
        reload()
        return record
    }

    func delete(_ record: MemoryRecord) {
        context.delete(record)
        try? context.save()
        reload()
    }

    func clear() {
        for record in items { context.delete(record) }
        try? context.save()
        reload()
    }

    func search(_ query: String, limit: Int = 6) -> [MemoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let tokens = trimmed.split { $0.isWhitespace || $0.isPunctuation }.map(String.init)
        return items
            .map { record -> (MemoryRecord, Int) in
                let score = tokens.reduce(0) { partial, token in
                    partial + (record.text.localizedCaseInsensitiveContains(token) ? 1 : 0)
                }
                return (record, score)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { pair -> MemoryRecord in
                pair.0.lastUsedAt = Date()
                pair.0.uses += 1
                return pair.0
            }
    }

    /// 拼进系统提示的那一段。
    func promptSection(limit: Int = 20) -> String {
        guard !items.isEmpty else { return "" }
        let lines = items.prefix(limit).map { "• [\($0.kind.title)] \($0.text)" }
        return "\n## 你记得的事\n" + lines.joined(separator: "\n")
    }
}

// MARK: - 工具

@MainActor
final class MemoryTool: AgentTool {
    private let store: MemoryStore

    init(store: MemoryStore) { self.store = store }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "memory",
            summary: "记住一件事、按关键词回忆、列出全部、删除。action=add/search/list/forget。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("add | search | list | forget"),
                "text": .stringParam("要记住的内容，或搜索关键词"),
                "kind": .stringParam("fact | preference | contact | routine | secret"),
                "id": .stringParam("删除时的 id")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let action = arguments["action"]?.stringValue ?? "list"
        switch action {
        case "add":
            guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
                throw ToolError.badInput("缺少 text")
            }
            let kind = MemoryKind(rawValue: arguments["kind"]?.stringValue ?? "fact") ?? .fact
            store.add(text, kind: kind)
            return .ok("记住了：\(text)")

        case "search":
            let query = arguments["text"]?.stringValue ?? ""
            let results = store.search(query)
            guard !results.isEmpty else { return .ok("没有相关的记忆") }
            return .ok(results.map { "• \($0.text)" }.joined(separator: "\n"))

        case "list":
            guard !store.items.isEmpty else { return .ok("还没有任何记忆") }
            return .ok(store.items.map { "• [\($0.kind.title)] \($0.text)" }.joined(separator: "\n"))

        case "forget":
            guard let id = arguments["id"]?.stringValue,
                  let record = store.items.first(where: { $0.id == id }) else {
                throw ToolError.badInput("找不到这条记忆")
            }
            store.delete(record)
            return .ok("已删除")

        default:
            throw ToolError.badInput("未知动作：\(action)")
        }
    }
}

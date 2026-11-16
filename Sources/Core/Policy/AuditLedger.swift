import Foundation
import Observation

/// 只追加的审计账本：每一次看屏、点按、命令、审批都留痕。
/// 上限 5000 条，落盘为 JSONL，方便导出和回放。
@MainActor
@Observable
final class AuditLedger {
    struct Entry: Codable, Identifiable, Hashable {
        enum Kind: String, Codable {
            case userMessage, modelText, toolCall, toolResult, approval, error, system
        }

        var id: String = UUID().uuidString
        var kind: Kind
        var title: String
        var detail: String
        var risk: RiskLevel
        var date: Date = Date()
        var runID: String?
        var duration: TimeInterval?
    }

    private(set) var entries: [Entry] = []
    private let limit = 5000
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pogent", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("audit.jsonl")
        load()
    }

    func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        persist(entry)
    }

    func entries(forRun runID: String) -> [Entry] {
        entries.filter { $0.runID == runID }
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func export() -> String {
        entries.map { entry in
            let formatter = ISO8601DateFormatter()
            return "[\(formatter.string(from: entry.date))] \(entry.kind.rawValue) \(entry.title) — \(entry.detail)"
        }.joined(separator: "\n")
    }

    private func persist(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = text.split(separator: "\n").suffix(limit)
        entries = lines.compactMap { line in
            try? decoder.decode(Entry.self, from: Data(line.utf8))
        }
    }
}

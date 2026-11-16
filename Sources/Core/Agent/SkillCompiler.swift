import Foundation
import SwiftData

/// 把一次成功的执行编译成可复用的技能。
///
/// Poki 的 routine 是“同一个 App 里的一串动作”；
/// Fish 的插件是“一段可加载的代码”。
/// pogent 把两者合成 Skill：触发条件 + 工具序列 + 参数占位符，
/// 既能一键重跑，也能导出给别的设备。
struct CompiledSkill: Codable, Sendable {
    struct Step: Codable, Sendable {
        var tool: String
        var arguments: String
        var surface: String
        var risk: Int
    }

    var name: String
    var summary: String
    var goal: String
    var steps: [Step]
    var createdAt: Date
    var originApp: String?
}

@MainActor
final class SkillCompiler {
    private let context: ModelContext
    private let ledger: AuditLedger

    init(context: ModelContext, ledger: AuditLedger) {
        self.context = context
        self.ledger = ledger
    }

    /// 把一次运行里的工具调用抽出来，参数里的具体值换成 {{占位符}}。
    func compile(runID: String, goal: String, originApp: String?, steps: [StepRecord]) throws -> SkillRecord {
        let toolSteps = steps.filter { $0.status == .done }.map { step in
            CompiledSkill.Step(
                tool: step.title,
                arguments: step.detail,
                surface: step.surface.rawValue,
                risk: step.risk.rawValue
            )
        }
        guard !toolSteps.isEmpty else { throw ToolError.unavailable("这次运行没有可复用的步骤") }

        let skill = CompiledSkill(
            name: Self.name(from: goal),
            summary: "由一次成功运行生成，共 \(toolSteps.count) 步",
            goal: goal,
            steps: toolSteps,
            createdAt: Date(),
            originApp: originApp
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(data: (try? encoder.encode(skill)) ?? Data(), encoding: .utf8) ?? "{}"

        let record = SkillRecord(
            name: skill.name,
            summary: skill.summary,
            goalTemplate: goal,
            stepsJSON: json
        )
        context.insert(record)
        try context.save()
        ledger.append(.init(kind: .system, title: "生成技能", detail: skill.name, risk: .safe, runID: runID))
        return record
    }

    private static func name(from goal: String) -> String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(18))
    }
}

/// Poki 风格的例程：一个 App 内的一串界面动作，可以带参数重放。
@MainActor
@Observable
final class RoutineStore {
    struct Routine: Codable, Identifiable {
        var id: String = UUID().uuidString
        var name: String
        var bundleID: String
        var actions: [ControlAction]
        var createdAt: Date = Date()
        var runs: Int = 0
    }

    private(set) var routines: [Routine] = []
    private let fileURL: URL

    init(workspace: URL) {
        fileURL = workspace.appendingPathComponent("routines.json")
        load()
    }

    func save(name: String, bundleID: String, actions: [ControlAction]) {
        if let index = routines.firstIndex(where: { $0.name == name }) {
            routines[index].actions = actions
            routines[index].bundleID = bundleID
        } else {
            routines.append(Routine(name: name, bundleID: bundleID, actions: actions))
        }
        persist()
    }

    func routine(named name: String) -> Routine? {
        routines.first { $0.name == name }
    }

    func markRun(_ name: String) {
        guard let index = routines.firstIndex(where: { $0.name == name }) else { return }
        routines[index].runs += 1
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(routines) {
            try? data.write(to: fileURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Routine].self, from: data) else { return }
        routines = decoded
    }
}

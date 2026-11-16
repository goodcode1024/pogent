import Foundation
import Observation

/// 所有工具的注册表。模型只看到这里声明过的东西。
@MainActor
@Observable
final class ToolRegistry {
    private(set) var tools: [String: any AgentTool] = [:]
    private(set) var order: [String] = []

    func register(_ tool: any AgentTool) {
        let name = tool.definition.name
        if tools[name] == nil { order.append(name) }
        tools[name] = tool
    }

    func register(_ list: [any AgentTool]) {
        for tool in list { register(tool) }
    }

    func tool(named name: String) -> (any AgentTool)? { tools[name] }

    func definition(named name: String) -> ToolDefinition? { tools[name]?.definition }

    /// 交给模型的工具清单。按「系统能力 → 运行时 → 界面操控」排序，
    /// 让模型自然优先选择便宜的那一层。
    func modelManifest(surfaces: Set<ExecutionSurface> = Set(ExecutionSurface.allCases)) -> String {
        let selected = order
            .compactMap { tools[$0]?.definition }
            .filter { surfaces.contains($0.surface) }
            .sorted { lhs, rhs in
                if lhs.surface.priority != rhs.surface.priority {
                    return lhs.surface.priority < rhs.surface.priority
                }
                return lhs.name < rhs.name
            }

        return selected.map { definition in
            """
            - \(definition.name) [\(definition.surface.rawValue)] 风险:\(definition.risk.title)
              说明: \(definition.summary)
              参数: \(definition.parameters.compactDescription)
            """
        }.joined(separator: "\n")
    }

    var count: Int { tools.count }

    var surfaceCounts: [ExecutionSurface: Int] {
        var counts: [ExecutionSurface: Int] = [:]
        for tool in tools.values {
            counts[tool.definition.surface, default: 0] += 1
        }
        return counts
    }
}

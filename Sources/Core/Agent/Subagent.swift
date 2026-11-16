import Foundation

/// 子智能体：把一件独立的小事交给另一个循环去跑，跑完只把结论带回来。
///
/// 上下文不会互相污染，长任务也不会把主对话撑爆。
@MainActor
final class SubagentRunner {
    struct Result {
        var text: String
        var toolCalls: [String]
    }

    private let registry: ToolRegistry
    private let router = ModelRouter()

    init(registry: ToolRegistry) {
        self.registry = registry
    }

    func run(
        goal: String,
        allowedTools: Set<String>?,
        config: ModelConfig,
        context: ToolContext,
        maxRounds: Int = 10
    ) async -> Result {
        var messages: [ModelMessage] = [ModelMessage(role: .user, text: goal)]
        var used: [String] = []

        let definitions = registry.order
            .compactMap { registry.tool(named: $0)?.definition }
            .filter { definition in
                guard let allowedTools else { return definition.name != "spawn_subagent" }
                return allowedTools.contains(definition.name)
            }
            .filter { $0.name != "spawn_subagent" }

        let system = """
        你是 pogent 的子智能体，只负责这一件小事：\(goal)

        规则：
        - 只做这件事，不扩展任务，不闲聊。
        - 能用工具就用工具，不要凭记忆编事实。
        - 最多 \(maxRounds) 轮，做完立刻给结论。
        - 结论写给主智能体看：直接说结果和你做过的关键动作，不要客套。
        """

        for _ in 0..<maxRounds {
            let request = ModelRequest(
                system: system,
                messages: messages,
                tools: definitions,
                temperature: config.temperature,
                maxTokens: min(config.maxTokens, 2048)
            )
            let provider = router.provider(for: request, config: config)

            var text = ""
            var calls: [ToolInvocation] = []
            do {
                for try await delta in provider.stream(request) {
                    switch delta {
                    case .text(let chunk): text += chunk
                    case .toolCalls(let batch): calls.append(contentsOf: batch)
                    default: break
                    }
                }
            } catch {
                return Result(text: "子任务失败：\(error.localizedDescription)", toolCalls: used)
            }

            guard !calls.isEmpty else {
                return Result(text: text.isEmpty ? "子任务没有产出。" : text, toolCalls: used)
            }

            messages.append(ModelMessage(role: .assistant, text: text, toolCalls: calls))
            for call in calls {
                used.append(call.name)
                let outcome = await execute(call, context: context)
                messages.append(ModelMessage(
                    role: .tool,
                    text: outcome.modelText,
                    toolCallID: call.id,
                    toolName: call.name
                ))
            }
        }

        return Result(text: "子任务达到步数上限，没有做完。已执行：\(used.joined(separator: "、"))", toolCalls: used)
    }

    private func execute(_ call: ToolInvocation, context: ToolContext) async -> ToolOutcome {
        guard let tool = registry.tool(named: call.name) else {
            return .failed("没有这个工具：\(call.name)")
        }
        // 子智能体不重复走运行时审批，但工具自己需要确认的仍然会问。
        do {
            return try await tool.call(call.arguments, context: context)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

@MainActor
final class SubagentTool: AgentTool {
    private let registry: ToolRegistry
    private let configProvider: () -> ModelConfig

    init(registry: ToolRegistry, config: @escaping () -> ModelConfig) {
        self.registry = registry
        self.configProvider = config
    }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "spawn_subagent",
            summary: "把一件独立的小事交给子智能体去跑，只拿回结论。适合调研、批量处理、长链路任务。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "goal": .stringParam("要它完成的具体目标，写清楚验收标准"),
                "tools": .arrayParam("允许它使用的工具名，留空表示除子智能体外全部可用")
            ], required: ["goal"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let goal = arguments["goal"]?.stringValue, !goal.isEmpty else {
            throw ToolError.badInput("缺少 goal")
        }
        let names = (arguments["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
        let allowed: Set<String>? = names.isEmpty ? nil : Set(names)

        let runner = SubagentRunner(registry: registry)
        let result = await runner.run(
            goal: goal,
            allowedTools: allowed,
            config: configProvider(),
            context: context
        )
        return .ok(result.text, payload: .object([
            "tools": .array(result.toolCalls.map { .string($0) })
        ]))
    }
}

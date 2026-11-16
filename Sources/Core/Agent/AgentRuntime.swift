import Foundation
import SwiftData
import Observation

/// 单个回合的执行者：取上下文 → 问模型 → 调工具 → 再问，直到给出答案。
@MainActor
@Observable
final class AgentRuntime {
    // 对外状态
    private(set) var isRunning = false
    private(set) var streamingText = ""
    private(set) var steps: [StepRecord] = []
    private(set) var currentRun: RunRecord?
    private(set) var lastError: String?
    var modelConfig: ModelConfig

    // 依赖
    let registry: ToolRegistry
    let approvals: ApprovalEngine
    let ledger: AuditLedger
    let control: DeviceControlService
    let shell: ShellSession
    private let router = ModelRouter()
    private let activity = TaskActivityManager()

    var maxSteps = 40
    /// 这些工具自己会发起审批，运行时不再重复问一遍。
    private let selfApprovingTools: Set<String> = ["do", "compose_message"]

    init(
        registry: ToolRegistry,
        approvals: ApprovalEngine,
        ledger: AuditLedger,
        control: DeviceControlService,
        shell: ShellSession,
        modelConfig: ModelConfig
    ) {
        self.registry = registry
        self.approvals = approvals
        self.ledger = ledger
        self.control = control
        self.shell = shell
        self.modelConfig = modelConfig
    }

    // MARK: - 入口

    func submit(_ input: String, conversation: Conversation, context: ModelContext) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }

        // 聊天里的一句“可以”就能放行正在等待的审批。
        if approvals.pending.isEmpty == false, Self.looksLikeConsent(text) {
            approvals.approveOldest()
            append(role: .assistant, text: "好，继续。", conversation: conversation, context: context)
            return
        }

        isRunning = true
        streamingText = ""
        lastError = nil
        steps = []
        defer {
            isRunning = false
            streamingText = ""
        }

        append(role: .user, text: text, conversation: conversation, context: context)
        conversation.updatedAt = Date()
        conversation.lastText = text
        try? context.save()

        let run = RunRecord(conversationID: conversation.id, goal: text)
        context.insert(run)
        currentRun = run
        ledger.append(.init(kind: .userMessage, title: "用户", detail: text, risk: .safe, runID: run.id))

        activity.start(runID: run.id, title: conversation.title, step: "正在理解任务")

        var messages = buildMessages(conversation: conversation, context: context, latest: text)
        let system = systemPrompt()

        do {
            try await loop(run: run, conversation: conversation, context: context, messages: messages, system: system)
            run.state = .done
            run.endedAt = Date()
        } catch is CancellationError {
            run.state = .cancelled
            run.endedAt = Date()
            append(role: .assistant, text: "已停止。", conversation: conversation, context: context)
        } catch {
            run.state = .failed
            run.endedAt = Date()
            lastError = error.localizedDescription
            ledger.append(.init(kind: .error, title: "运行失败", detail: error.localizedDescription, risk: .safe, runID: run.id))
            append(role: .assistant, text: "这一步出错了：\(error.localizedDescription)", conversation: conversation, context: context)
        }

        try? context.save()
        await activity.finish(summary: run.state == .done ? "完成" : "结束")
        currentRun = nil
    }

    func stop() {
        control.stop()
        approvals.resolveAll(expired: false)
        Task { await activity.stop() }
    }

    // MARK: - 循环

    private func loop(
        run: RunRecord,
        conversation: Conversation,
        context: ModelContext,
        messages initialMessages: [ModelMessage],
        system: String
    ) async throws {
        var messages = initialMessages
        var round = 0

        while round < maxSteps {
            try Task.checkCancellation()
            round += 1

            let definitions = registry.tools.values.map { $0.definition }
            let request = ModelRequest(
                system: system,
                messages: messages,
                tools: definitions,
                temperature: modelConfig.temperature,
                maxTokens: modelConfig.maxTokens
            )

            let provider = router.provider(for: request, config: modelConfig)
            var assistantText = ""
            var reasoningText = ""
            var toolCalls: [ToolInvocation] = []
            var usage = 0

            streamingText = ""
            for try await delta in provider.stream(request) {
                switch delta {
                case .text(let chunk):
                    assistantText += chunk
                    streamingText = assistantText
                case .reasoning(let chunk):
                    // 思考内容不进气泡，只留在这轮上下文里回传给模型
                    reasoningText += chunk
                case .toolCalls(let calls):
                    toolCalls.append(contentsOf: calls)
                case .usage(let input, let output):
                    usage += input + output
                case .finished:
                    break
                }
            }

            run.tokenEstimate += usage
            streamingText = ""

            if !assistantText.isEmpty {
                append(role: .assistant, text: assistantText, conversation: conversation, context: context, runID: run.id)
                ledger.append(.init(kind: .modelText, title: "pogent", detail: String(assistantText.prefix(400)), risk: .safe, runID: run.id))
            }

            guard !toolCalls.isEmpty else { return }

            let echo = reasoningText.isEmpty ? nil : reasoningText
            messages.append(ModelMessage(
                role: .assistant,
                text: assistantText,
                toolCalls: toolCalls,
                reasoningContent: modelConfig.shouldEchoReasoning ? echo : nil
            ))

            for call in toolCalls {
                try Task.checkCancellation()
                let result = await execute(call, run: run, conversation: conversation)
                messages.append(ModelMessage(
                    role: .tool,
                    text: result.modelText,
                    toolCallID: call.id,
                    toolName: call.name
                ))
            }
        }

        append(role: .assistant, text: "任务步骤太多，我先停在这里。你可以让我继续，或把目标拆小一点。",
               conversation: conversation, context: context, runID: run.id)
    }

    // MARK: - 执行单个工具

    private func execute(_ call: ToolInvocation, run: RunRecord, conversation: Conversation) async -> ToolOutcome {
        guard let tool = registry.tool(named: call.name) else {
            return .failed("没有这个工具：\(call.name)")
        }
        let definition = tool.definition

        let step = StepRecord(
            runID: run.id,
            index: steps.count + 1,
            title: definition.name,
            detail: call.arguments.compactDescription,
            surface: definition.surface,
            risk: definition.risk
        )
        steps.append(step)
        run.stepCount = steps.count
        currentRun = run

        await activity.update(
            step: "\(definition.surface.title) · \(definition.name)",
            index: steps.count,
            total: steps.count
        )

        let started = Date()

        // 通用审批：资金类永远问，其余按策略。
        if !selfApprovingTools.contains(definition.name),
           let request = approvals.requiredApproval(for: definition, summary: summary(for: call), context: toolContext(run: run, conversation: conversation)) {
            run.state = .waitingApproval
            await activity.update(step: "等你确认", index: steps.count, total: steps.count, approval: request)
            let decision = await approvals.waitForDecision(request)
            run.state = .running

            switch decision {
            case .allowed:
                break
            case .denied(let reason):
                step.status = .denied
                step.duration = Date().timeIntervalSince(started)
                return .denied(reason)
            case .expired:
                step.status = .denied
                step.duration = Date().timeIntervalSince(started)
                return .denied("确认超时，画面可能已经变化，我先不做了")
            case .handoff:
                step.status = .failed
                step.duration = Date().timeIntervalSince(started)
                return .needsHuman("需要你本人完成", kind: "handoff")
            }
        }

        do {
            let outcome = try await tool.call(call.arguments, context: toolContext(run: run, conversation: conversation))
            step.duration = Date().timeIntervalSince(started)
            step.status = outcome.status == .ok ? .done : (outcome.status == .denied ? .denied : .failed)
            ledger.append(.init(
                kind: .toolResult,
                title: "\(call.name) · \(outcome.status.rawValue)",
                detail: outcome.summary,
                risk: definition.risk,
                runID: run.id,
                duration: step.duration
            ))
            return outcome
        } catch {
            step.duration = Date().timeIntervalSince(started)
            step.status = .failed
            ledger.append(.init(
                kind: .error,
                title: "\(call.name) 失败",
                detail: error.localizedDescription,
                risk: definition.risk,
                runID: run.id,
                duration: step.duration
            ))
            return .failed(error.localizedDescription)
        }
    }

    private func toolContext(run: RunRecord, conversation: Conversation) -> ToolContext {
        ToolContext(
            runID: run.id,
            conversationID: conversation.id,
            workspace: shell.workspace,
            originApp: control.originAppName,
            requestApproval: { [weak self] request in
                guard let self else { return .denied(reason: "运行已结束") }
                await self.activity.update(step: "等你确认", index: self.steps.count, total: self.steps.count, approval: request)
                return await self.approvals.waitForDecision(request)
            },
            recordActivity: { [weak self] text in
                self?.ledger.append(.init(kind: .system, title: "活动", detail: text, risk: .safe, runID: run.id))
            }
        )
    }

    private func summary(for call: ToolInvocation) -> String {
        let preview = call.arguments.compactDescription
        return "\(call.name) \(preview.prefix(180))"
    }

    // MARK: - 上下文

    private func buildMessages(conversation: Conversation, context: ModelContext, latest: String) -> [ModelMessage] {
        let history = ChatMessage.history(for: conversation.id, in: context, limit: 40)
        var messages: [ModelMessage] = history.compactMap { message in
            switch message.role {
            case .user: ModelMessage(role: .user, text: message.text)
            case .assistant: message.text.isEmpty ? nil : ModelMessage(role: .assistant, text: message.text)
            default: nil
            }
        }
        // 最后一条就是刚写入的用户消息，避免重复。
        if messages.last?.text == latest { messages.removeLast() }
        messages.append(ModelMessage(role: .user, text: latest))
        return messages
    }

    private func systemPrompt() -> String {
        """
        你是 pogent，跑在 iPhone / iPad 本机的智能体。最低系统 iOS 27。

        ## 能力分层（务必按这个顺序选）
        1. native（系统能力）：日历、提醒、通讯录、健康、照片、地图、家庭、剪贴板、通知、网页抓取、内置浏览器。最可靠。
        2. shell（本机运行时）：终端、文件、git、ffmpeg、python、node。适合批处理和代码。
        3. ui（界面操控）：当某个 App 没有 API 时才用。先 look 读屏，再用 do 执行动作，最后再读一次确认画面变化。

        能用第 1 层就不要用第 2 层，能用第 2 层就不要点界面。

        ## 界面操控规则
        - look 返回带编号的元素，do 里用这些编号。编号在两次读屏之间保持稳定。
        - 一次 do 最多 12 个动作。做完看 diff：新增/变化/消失分别是什么。
        - 点按前确认目标元素的文字，别点错。找不到元素就重新 look，不要猜坐标。
        - 付款、删除、发消息、Wallet、密码：先停下来等用户确认。密码和验证码永远留给用户本人。
        - 任务结束用 finish=true，回到用户发起任务时的 App。

        ## 回答风格
        - 中文，短句，直接给结果。
        - 做完一件事，用一句话说明改了什么，必要时附上文件路径或时间。
        - 失败时说清楚卡在哪一步、下一步建议，不要假装成功。

        当前设备：iOS 27，工作区 \(shell.workspace.lastPathComponent)，可用工具 \(registry.count) 个。
        """
    }

    // MARK: - 写入

    private func append(
        role: MessageRole,
        text: String,
        conversation: Conversation,
        context: ModelContext,
        runID: String? = nil
    ) {
        guard !text.isEmpty else { return }
        let message = ChatMessage(conversationID: conversation.id, role: role, text: text, runID: runID)
        context.insert(message)
        conversation.updatedAt = Date()
        conversation.lastText = String(text.prefix(80))
        try? context.save()
    }

    private static func looksLikeConsent(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let keywords = ["可以", "允许", "同意", "发吧", "确认", "继续", "ok", "yes", "approve", "allow"]
        return normalized.count <= 12 && keywords.contains { normalized.contains($0) }
    }
}

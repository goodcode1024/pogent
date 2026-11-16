import Foundation
import Observation

// MARK: - 策略

enum ApprovalMode: String, Codable, CaseIterable, Sendable {
    case never          // 从不询问（不建议）
    case confirm        // 每次要确认
    case messageReply   // 拒绝执行，回到对话里问

    var title: String {
        switch self {
        case .never: "从不询问"
        case .confirm: "即时确认"
        case .messageReply: "回到对话确认"
        }
    }
}

enum ApprovalSensitivity: Int, Codable, CaseIterable, Sendable {
    case permissive = 0   // 只拦资金和删除
    case balanced = 1     // 拦敏感及以上
    case strict = 2       // 几乎都拦
    case everything = 3   // 全拦

    var title: String {
        switch self {
        case .permissive: "宽松"
        case .balanced: "均衡"
        case .strict: "严格"
        case .everything: "全部询问"
        }
    }
}

struct ApprovalPolicy: Codable, Sendable {
    var mode: ApprovalMode = .confirm
    var sensitivity: ApprovalSensitivity = .balanced
    /// 同一会话内放行过的同类操作，45 秒内不再重复问。
    var coalescingWindow: TimeInterval = 45
    /// 金额阈值：超过就要人确认。
    var paymentThreshold: Decimal = 50
    /// 按 App 的额外规则，key 是 bundle id。
    var perAppRules: [String: ApprovalMode] = [:]
}

// MARK: - 请求与决定

struct ApprovalRequest: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case generic
        case message
        case payment
        case deletion
        case wallet
        case password
        case phoneCall
    }

    let id: String
    var runID: String
    var toolName: String
    var title: String
    var detail: String
    var risk: RiskLevel
    var kind: Kind
    var appName: String?
    var expiresIn: TimeInterval

    init(
        id: String = UUID().uuidString,
        runID: String,
        toolName: String,
        title: String,
        detail: String,
        risk: RiskLevel,
        kind: Kind = .generic,
        appName: String? = nil,
        expiresIn: TimeInterval = 120
    ) {
        self.id = id
        self.runID = runID
        self.toolName = toolName
        self.title = title
        self.detail = detail
        self.risk = risk
        self.kind = kind
        self.appName = appName
        self.expiresIn = expiresIn
    }

    var needsHandoff: Bool {
        kind == .password
    }
}

enum ApprovalDecision: Sendable {
    case allowed(rememberForSession: Bool)
    case denied(reason: String)
    case expired
    case handoff

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

// MARK: - 引擎

@MainActor
@Observable
final class ApprovalEngine {
    var policy = ApprovalPolicy()
    private(set) var pending: [ApprovalRequest] = []
    private(set) var recent: [ApprovalRecord] = []

    /// 最近一次放行：用于 45 秒合并窗口。
    @ObservationIgnored private var lastGrant: (signature: String, at: Date)?

    @ObservationIgnored private var continuations: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]
    @ObservationIgnored private var timeoutTasks: [String: Task<Void, Never>] = [:]

    private let ledger: AuditLedger

    init(ledger: AuditLedger) {
        self.ledger = ledger
    }

    // MARK: 判定

    /// 返回 nil 表示可以直接执行，不需要人。
    func requiredApproval(for definition: ToolDefinition, summary: String, context: ToolContext) -> ApprovalRequest? {
        guard policy.mode != .never else { return nil }

        // 资金类永不自动放行。
        guard !definition.risk.alwaysAsksHuman else {
            return ApprovalRequest(
                runID: context.runID,
                toolName: definition.name,
                title: "确认付款",
                detail: summary,
                risk: definition.risk,
                kind: .payment,
                appName: context.originApp,
                expiresIn: 120
            )
        }

        switch policy.sensitivity {
        case .permissive:
            guard definition.risk >= .destructive else { return nil }
        case .balanced:
            guard definition.risk >= .sensitive else { return nil }
        case .strict:
            guard definition.risk >= .sensitive || definition.surface == .ui else { return nil }
        case .everything:
            break
        }

        let signature = "\(definition.name)|\(summary)"
        if let lastGrant, lastGrant.signature == signature,
           Date().timeIntervalSince(lastGrant.at) < policy.coalescingWindow {
            return nil
        }

        return ApprovalRequest(
            runID: context.runID,
            toolName: definition.name,
            title: approvalTitle(for: definition),
            detail: summary,
            risk: definition.risk,
            kind: definition.risk == .destructive ? .deletion : .generic,
            appName: context.originApp
        )
    }

    private func approvalTitle(for definition: ToolDefinition) -> String {
        switch definition.risk {
        case .safe: "允许读取"
        case .sensitive: "允许这一步"
        case .destructive: "确认删除"
        case .financial: "确认付款"
        }
    }

    // MARK: 等待

    func waitForDecision(_ request: ApprovalRequest) async -> ApprovalDecision {
        pending.append(request)

        if request.needsHandoff {
            pending.removeAll { $0.id == request.id }
            ledger.append(.init(
                kind: .approval,
                title: request.title,
                detail: "已转交本人处理：\(request.detail)",
                risk: request.risk
            ))
            return .handoff
        }

        let decision = await withCheckedContinuation { continuation in
            continuations[request.id] = continuation
            timeoutTasks[request.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(request.expiresIn))
                guard !Task.isCancelled else { return }
                self?.resolve(request.id, decision: .expired, reason: "超时未答复")
            }
        }
        return decision
    }

    func resolve(_ id: String, decision: ApprovalDecision, reason: String? = nil) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
        let request = pending.first(where: { $0.id == id })
        pending.removeAll { $0.id == id }
        recent.insert(ApprovalRecord(
            id: id,
            title: request?.title ?? "审批",
            detail: reason ?? decisionDescription(decision),
            risk: request?.risk ?? .sensitive,
            date: Date()
        ), at: 0)
        if recent.count > 200 { recent.removeLast(recent.count - 200) }

        if case .allowed(let remember) = decision, let request {
            let signature = "\(request.toolName)|\(request.detail)"
            lastGrant = (signature, Date())
            if remember {
                policy.sensitivity = .permissive
                policy.mode = .never
            }
        }

        ledger.append(.init(
            kind: .approval,
            title: "审批：\(request?.title ?? "操作")",
            detail: decisionDescription(decision),
            risk: request?.risk ?? .sensitive
        ))

        continuation.resume(returning: decision)
    }

    func resolveAll(expired: Bool) {
        for request in pending {
            resolve(request.id, decision: expired ? .expired : .denied(reason: "已取消"))
        }
    }

    private func decisionDescription(_ decision: ApprovalDecision) -> String {
        switch decision {
        case .allowed(let remember): remember ? "已允许（本会话不再询问）" : "已允许"
        case .denied(let reason): "已拒绝：\(reason)"
        case .expired: "超时，未执行"
        case .handoff: "转交本人"
        }
    }

    /// 聊天里的一句话授权（“可以，发吧”）可以放行当前等待项。
    func approveOldest() {
        guard let first = pending.first else { return }
        resolve(first.id, decision: .allowed(rememberForSession: false))
    }
}

struct ApprovalRecord: Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String
    var risk: RiskLevel
    var date: Date
}

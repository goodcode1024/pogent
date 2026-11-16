import Foundation
import Observation

/// 远程会话：把电脑和服务器上的 Codex / Claude Code / DSH 会话
/// 放进同一个列表，和本机会话一样跟进、审批、打断。
struct RemoteAgentSession: Identifiable, Codable, Hashable, Sendable {
    enum Agent: String, Codable, Sendable {
        case codex, claudeCode, dsh, pogent

        var title: String {
            switch self {
            case .codex: "Codex"
            case .claudeCode: "Claude Code"
            case .dsh: "DSH"
            case .pogent: "pogent"
            }
        }
    }

    enum State: String, Codable, Sendable {
        case idle, running, waitingApproval, failed, done
    }

    var id: String
    var hostName: String
    var agent: Agent
    var title: String
    var state: State
    var lastMessage: String
    var updatedAt: Date

    var symbol: String {
        switch agent {
        case .codex: "terminal"
        case .claudeCode: "sparkles"
        case .dsh: "fish"
        case .pogent: "p.circle"
        }
    }
}

@MainActor
@Observable
final class RemoteSessionService {
    private(set) var sessions: [RemoteAgentSession] = []
    private(set) var isConnected = false
    private(set) var pairingCode: String?
    private(set) var lastError: String?

    private var socket: URLSessionWebSocketTask?
    private var host: URL?

    /// 配对走同一个局域网或用户自建的中转；不登录就什么都不会发生。
    func pair(code: String) async throws {
        guard let url = URL(string: "wss://relay.pogent.local/v1/pair/\(code)") else {
            throw ToolError.badInput("配对码不对")
        }
        host = url
        try await connect(url)
        pairingCode = code
    }

    func connect(_ url: URL) async throws {
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        isConnected = true
        receive()
    }

    func disconnect() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isConnected = false
    }

    func refresh() async {
        guard let socket else { return }
        do {
            try await socket.send(.string(#"{"op":"list"}"#))
        } catch {
            lastError = error.localizedDescription
            isConnected = false
        }
    }

    func send(_ text: String, to session: RemoteAgentSession) async {
        guard let socket else { return }
        let payload = #"{"op":"say","session":"\#(session.id)","text":"\#(text.replacingOccurrences(of: "\"", with: "\\\""))"}"#
        try? await socket.send(.string(payload))
    }

    func approve(_ session: RemoteAgentSession) async {
        guard let socket else { return }
        try? await socket.send(.string(#"{"op":"approve","session":"\#(session.id)"}"#))
    }

    func interrupt(_ session: RemoteAgentSession) async {
        guard let socket else { return }
        try? await socket.send(.string(#"{"op":"interrupt","session":"\#(session.id)"}"#))
    }

    private func receive() {
        Task { [weak self] in
            guard let socket = self?.socket else { return }
            while true {
                do {
                    let message = try await socket.receive()
                    self?.handle(message)
                } catch {
                    self?.lastError = error.localizedDescription
                    self?.isConnected = false
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let op = object["op"] as? String else { return }

        if op == "sessions", let list = object["sessions"] as? [[String: Any]] {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = list.compactMap { item in
                guard let itemData = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                return try? decoder.decode(RemoteAgentSession.self, from: itemData)
            }
        }
    }
}

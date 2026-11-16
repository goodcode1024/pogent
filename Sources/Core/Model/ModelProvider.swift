import Foundation
import FoundationModels

// MARK: - 消息

struct ModelMessage: Sendable {
    enum Role: String, Sendable { case system, user, assistant, tool }

    var role: Role
    var text: String
    var toolCalls: [ToolInvocation] = []
    var toolCallID: String?
    var toolName: String?
    /// 思考模型的推理内容。工具调用链里必须原样回传，否则部分厂商会 400。
    var reasoningContent: String?
}

struct ModelRequest: Sendable {
    var system: String
    var messages: [ModelMessage]
    var tools: [ToolDefinition]
    var temperature: Double = 0.2
    var maxTokens: Int = 4096
}

enum ModelDelta: Sendable {
    case text(String)
    /// 思考过程。界面默认不展示，但要留在这一轮的消息里回传给模型。
    case reasoning(String)
    case toolCalls([ToolInvocation])
    case usage(input: Int, output: Int)
    case finished(reason: String?)
}

// MARK: - 协议

protocol ModelProvider: AnyObject, Sendable {
    var displayName: String { get }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelDelta, Error>
}

enum ModelError: LocalizedError {
    case missingKey
    case badEndpoint
    case http(Int, String)
    case onDeviceUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingKey: "还没有填 API Key。"
        case .badEndpoint: "模型地址不对。"
        case .http(let code, let body): "模型返回 HTTP \(code)：\(body.prefix(200))"
        case .onDeviceUnavailable: "这台设备不支持端侧模型，请改用远端模型。"
        case .cancelled: "已取消。"
        }
    }
}

// MARK: - 端侧模型（iOS 27 Foundation Models）

/// 用来做三件便宜的事：任务分类、屏幕元素摘要、风险预判。
/// 复杂规划仍交给用户自己的大模型。
final class OnDeviceModelProvider: ModelProvider {
    let displayName = "端侧模型"

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard isAvailable else { throw ModelError.onDeviceUnavailable }
                    let session = LanguageModelSession(instructions: request.system)
                    let prompt = request.messages.last?.text ?? ""
                    var last = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        let content = partial.content
                        if content.count > last.count {
                            let delta = String(content.dropFirst(last.count))
                            last = content
                            continuation.yield(.text(delta))
                        }
                    }
                    continuation.yield(.finished(reason: "stop"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - OpenAI 兼容

struct ModelConfig: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case onDevice
        case openAICompatible
    }

    var kind: Kind = .onDevice
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = "gpt-4.1"
    var temperature: Double = 0.2
    var maxTokens: Int = 4096
    /// 语音转写 / 朗读用的模型（可选）。
    var voiceModel: String = ""
    /// 是否把思考内容回传给模型。思考模型必需；个别严格的普通模型会拒绝这个字段。
    /// 用可选类型是为了兼容旧版本存下来的配置（没有这个键也能解码）。
    var echoReasoning: Bool?

    static let `default` = ModelConfig()

    /// 默认开启：绝大多数 400 都是因为没回传 reasoning_content。
    var shouldEchoReasoning: Bool { echoReasoning ?? true }
}

final class OpenAICompatibleProvider: ModelProvider, @unchecked Sendable {
    let displayName: String
    private let config: ModelConfig
    private let apiKey: String

    init(config: ModelConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
        self.displayName = config.model
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: config.baseURL.hasSuffix("/") ? "\(config.baseURL)chat/completions" : "\(config.baseURL)/chat/completions") else {
                        throw ModelError.badEndpoint
                    }
                    guard !apiKey.isEmpty else { throw ModelError.missingKey }

                    var payload: [String: Any] = [
                        "model": config.model,
                        "stream": true,
                        "temperature": config.temperature,
                        "max_tokens": config.maxTokens,
                        "messages": request.messages.map(Self.encodeMessage)
                    ]
                    if !request.tools.isEmpty {
                        payload["tools"] = request.tools.map { definition in
                            [
                                "type": "function",
                                "function": [
                                    "name": definition.name,
                                    "description": definition.summary,
                                    "parameters": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(definition.parameters))) ?? [:]
                                ]
                            ]
                        }
                        payload["tool_choice"] = "auto"
                    }

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 120
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw ModelError.badEndpoint }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 500 { break } }
                        throw ModelError.http(http.statusCode, body)
                    }

                    var toolBuffers: [Int: (name: String, arguments: String)] = [:]

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if json == "[DONE]" { break }
                        guard let data = json.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = object["choices"] as? [[String: Any]],
                              let choice = choices.first else { continue }

                        if let delta = choice["delta"] as? [String: Any] {
                            if let thinking = delta["reasoning_content"] as? String, !thinking.isEmpty {
                                continuation.yield(.reasoning(thinking))
                            }
                            if let text = delta["content"] as? String, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                            if let calls = delta["tool_calls"] as? [[String: Any]] {
                                for call in calls {
                                    let index = call["index"] as? Int ?? 0
                                    var buffer = toolBuffers[index] ?? ("", "")
                                    if let function = call["function"] as? [String: Any] {
                                        if let name = function["name"] as? String, !name.isEmpty { buffer.name = name }
                                        if let args = function["arguments"] as? String { buffer.arguments += args }
                                    }
                                    toolBuffers[index] = buffer
                                }
                            }
                        }

                        if let usage = object["usage"] as? [String: Any],
                           let input = usage["prompt_tokens"] as? Int,
                           let output = usage["completion_tokens"] as? Int {
                            continuation.yield(.usage(input: input, output: output))
                        }

                        if let reason = choice["finish_reason"] as? String, reason != "null" {
                            if reason == "tool_calls" || !toolBuffers.isEmpty {
                                let calls = toolBuffers.sorted { $0.key < $1.key }.map { _, value in
                                    ToolInvocation(
                                        name: value.name,
                                        arguments: (try? JSONDecoder().decode(JSONValue.self, from: Data(value.arguments.utf8))) ?? .object([:])
                                    )
                                }
                                continuation.yield(.toolCalls(calls))
                            }
                            continuation.yield(.finished(reason: reason))
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func encodeMessage(_ message: ModelMessage) -> [String: Any] {
        var dictionary: [String: Any] = ["role": message.role.rawValue]

        if message.role == .tool {
            dictionary["content"] = message.text
            dictionary["tool_call_id"] = message.toolCallID ?? ""
            if let name = message.toolName { dictionary["name"] = name }
            return dictionary
        }

        dictionary["content"] = message.text
        if !message.toolCalls.isEmpty {
            dictionary["tool_calls"] = message.toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments.compactDescription
                    ]
                ]
            }
        }
        // 思考模型（DeepSeek V3.2 / GLM / Kimi 等）要求把上一轮 assistant 的
        // reasoning_content 原样带回来，否则 HTTP 400。普通模型没有这个字段就跳过。
        if message.role == .assistant,
           let thinking = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thinking.isEmpty {
            dictionary["reasoning_content"] = thinking
        }
        return dictionary
    }
}

// MARK: - 路由

/// 什么时候用端侧、什么时候用远端。省 token，也少把屏幕内容发出去。
@MainActor
final class ModelRouter {
    private let onDevice = OnDeviceModelProvider()

    /// 这一轮到底能不能真的调到模型。
    enum Resolution: Sendable {
        case remote       // 用户自己的 OpenAI 兼容接口
        case onDevice     // Apple 端侧模型
        case offline      // 都不可用，交给本地规则引擎
    }

    func resolution(for config: ModelConfig) -> Resolution {
        if config.kind == .openAICompatible {
            let key = KeychainStore.apiKey(for: config.kind.rawValue) ?? ""
            if !key.isEmpty { return .remote }
        }
        if onDevice.isAvailable { return .onDevice }
        return .offline
    }

    func provider(for request: ModelRequest, config: ModelConfig) -> any ModelProvider {
        switch resolution(for: config) {
        case .remote:
            return OpenAICompatibleProvider(
                config: config,
                apiKey: KeychainStore.apiKey(for: config.kind.rawValue) ?? ""
            )
        case .onDevice:
            return onDevice
        case .offline:
            // 上层会拦下来走 OfflineAssistant；真的走到这里说明判断有偏差，
            // 返回端侧 provider 让它抛一个明确的错误，而不是发一个空 Key 的请求。
            return onDevice
        }
    }

    private func shouldUseOnDevice(_ request: ModelRequest) -> Bool {
        let text = request.messages.last?.text ?? ""
        let simpleTask = request.tools.isEmpty && text.count < 240
        return simpleTask && onDevice.isAvailable
    }

    func classifyRisk(_ summary: String) async -> RiskLevel {
        guard onDevice.isAvailable else { return .sensitive }
        let request = ModelRequest(
            system: "你是一个风险分类器。只回答 safe、sensitive、destructive、financial 之一。",
            messages: [ModelMessage(role: .user, text: summary)],
            tools: []
        )
        var answer = ""
        do {
            for try await delta in onDevice.stream(request) {
                if case .text(let chunk) = delta { answer += chunk }
            }
        } catch {
            return .sensitive
        }
        let lowered = answer.lowercased()
        if lowered.contains("financial") { return .financial }
        if lowered.contains("destructive") { return .destructive }
        if lowered.contains("sensitive") { return .sensitive }
        return .safe
    }
}

// MARK: - Keychain

enum KeychainStore {
    private static let service = "bot.pogent.keys"

    static func save(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func apiKey(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

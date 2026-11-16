import Foundation
import SwiftData
import Observation

/// 外部服务连接器。凭证只进 Keychain，数据库里放元信息。
@MainActor
@Observable
final class ConnectorService {
    private let context: ModelContext
    private(set) var connectors: [ConnectorRecord] = []

    init(context: ModelContext) {
        self.context = context
        reload()
    }

    func reload() {
        let descriptor = FetchDescriptor<ConnectorRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        connectors = (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func add(kind: ConnectorKind, name: String, account: String, token: String, config: [String: String] = [:]) -> ConnectorRecord {
        let json = (try? JSONSerialization.data(withJSONObject: config))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let record = ConnectorRecord(kind: kind, displayName: name, account: account, configJSON: json)
        context.insert(record)
        if !token.isEmpty { KeychainStore.save(token, for: "connector.\(record.id)") }
        try? context.save()
        reload()
        return record
    }

    func remove(_ record: ConnectorRecord) {
        KeychainStore.delete("connector.\(record.id)")
        context.delete(record)
        try? context.save()
        reload()
    }

    func token(for record: ConnectorRecord) -> String {
        KeychainStore.apiKey(for: "connector.\(record.id)") ?? ""
    }

    func config(for record: ConnectorRecord) -> [String: String] {
        guard let data = record.configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    func markUsed(_ record: ConnectorRecord) {
        record.lastUsedAt = Date()
        try? context.save()
    }

    /// 取第一个可用且启用的某类连接器。
    func first(_ kind: ConnectorKind) -> ConnectorRecord? {
        connectors.first { $0.kind == kind && $0.isEnabled }
    }
}

// MARK: - 工具

@MainActor
final class ConnectorTool: AgentTool {
    private let service: ConnectorService

    init(service: ConnectorService) { self.service = service }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "connector",
            summary: """
            调用已连接的外部服务，action 取：
            list 列出连接、github_issues 看 issue、github_search 搜代码/仓库、github_create_issue 建 issue、
            webhook_post 发一个 JSON、rss 读订阅源、notion_query 查数据库。
            """,
            surface: .native,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("list | github_issues | github_search | github_create_issue | webhook_post | rss | notion_query"),
                "repo": .stringParam("owner/name"),
                "query": .stringParam("搜索词"),
                "title": .stringParam("issue 标题"),
                "body": .stringParam("issue 正文或 webhook 的 JSON"),
                "url": .stringParam("webhook / rss 地址"),
                "database": .stringParam("Notion database id")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let action = arguments["action"]?.stringValue ?? "list"

        switch action {
        case "list":
            guard !service.connectors.isEmpty else {
                return .ok("还没有连接任何服务。到「能力 → 连接器」添加 GitHub、Notion 或 Webhook。")
            }
            return .ok(service.connectors.map {
                "• \($0.kind.title) · \($0.displayName)\($0.isEnabled ? "" : "（已停用）")"
            }.joined(separator: "\n"))

        case "github_issues", "github_search", "github_create_issue":
            guard let github = service.first(.github) else {
                throw ToolError.unavailable("还没有连接 GitHub。到「能力 → 连接器」添加一个 Personal Access Token。")
            }
            return try await githubAction(action, arguments, record: github)

        case "webhook_post":
            guard let webhook = service.first(.webhook) else {
                throw ToolError.unavailable("还没有 Webhook 连接器")
            }
            guard let urlString = arguments["url"]?.stringValue ?? service.config(for: webhook)["url"],
                  let url = URL(string: urlString) else {
                throw ToolError.badInput("缺少 webhook 地址")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data((arguments["body"]?.stringValue ?? "{}").utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            service.markUsed(webhook)
            return .ok("Webhook 返回 HTTP \(code)：\(String(data: data.prefix(300), encoding: .utf8) ?? "")")

        case "rss":
            let urlString = arguments["url"]?.stringValue
                ?? service.first(.rss).flatMap { service.config(for: $0)["url"] }
            guard let urlString, let url = URL(string: urlString) else {
                throw ToolError.badInput("缺少订阅源地址")
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            let items = RSSParser.parse(data).prefix(12)
            guard !items.isEmpty else { return .ok("这个源里没有解析到条目") }
            return .ok(items.map { "• \($0.title)\n  \($0.link)" }.joined(separator: "\n"))

        case "notion_query":
            guard let notion = service.first(.notion) else {
                throw ToolError.unavailable("还没有连接 Notion")
            }
            guard let database = arguments["database"]?.stringValue
                    ?? service.config(for: notion)["database"], !database.isEmpty else {
                throw ToolError.badInput("缺少 database id")
            }
            var request = URLRequest(url: URL(string: "https://api.notion.com/v1/databases/\(database)/query")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(service.token(for: notion))", forHTTPHeaderField: "Authorization")
            request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
            let (data, _) = try await URLSession.shared.data(for: request)
            service.markUsed(notion)
            return .ok(String(data: data.prefix(4000), encoding: .utf8) ?? "")

        default:
            throw ToolError.badInput("未知动作：\(action)")
        }
    }

    private func githubAction(_ action: String, _ arguments: JSONValue, record: ConnectorRecord) async throws -> ToolOutcome {
        let token = service.token(for: record)
        guard !token.isEmpty else { throw ToolError.unavailable("GitHub 令牌是空的，请重新添加") }

        func request(_ path: String) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("pogent", forHTTPHeaderField: "User-Agent")
            return request
        }

        switch action {
        case "github_issues":
            guard let repo = arguments["repo"]?.stringValue else { throw ToolError.badInput("缺少 repo") }
            let (data, _) = try await URLSession.shared.data(for: request("/repos/\(repo)/issues?state=open&per_page=20"))
            service.markUsed(record)
            let issues = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let lines = issues.compactMap { issue -> String? in
                guard let number = issue["number"] as? Int, let title = issue["title"] as? String else { return nil }
                return "#\(number) \(title)"
            }
            return .ok(lines.isEmpty ? "没有打开的 issue" : lines.joined(separator: "\n"))

        case "github_search":
            guard let query = arguments["query"]?.stringValue else { throw ToolError.badInput("缺少 query") }
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let (data, _) = try await URLSession.shared.data(for: request("/search/repositories?q=\(encoded)&sort=stars&per_page=8"))
            service.markUsed(record)
            let items = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let lines = items.compactMap { item -> String? in
                guard let name = item["full_name"] as? String else { return nil }
                let stars = item["stargazers_count"] as? Int ?? 0
                return "• \(name) ★\(stars)"
            }
            return .ok(lines.isEmpty ? "没有搜到" : lines.joined(separator: "\n"))

        default:
            guard let repo = arguments["repo"]?.stringValue,
                  let title = arguments["title"]?.stringValue else {
                throw ToolError.badInput("需要 repo 和 title")
            }
            var issueRequest = request("/repos/\(repo)/issues")
            issueRequest.httpMethod = "POST"
            issueRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = ["title": title, "body": arguments["body"]?.stringValue ?? ""]
            issueRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: issueRequest)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            service.markUsed(record)
            if code == 201,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let url = object["html_url"] as? String {
                return .ok("已创建：\(url)")
            }
            return .failed("创建失败（HTTP \(code)）：\(String(data: data.prefix(300), encoding: .utf8) ?? "")")
        }
    }
}

// MARK: - RSS

/// 只做一件事：从 RSS / Atom 里抽出标题和链接。
/// 用正则而不是 XMLParser，避免代理回调跨线程的并发标注问题。
enum RSSParser {
    struct Item: Sendable {
        var title: String
        var link: String
    }

    static func parse(_ data: Data) -> [Item] {
        guard let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        var items: [Item] = []

        // RSS 2.0：<item><title>..</title><link>..</link></item>
        let rssPattern = #"<item[^>]*>([\s\S]*?)</item>"#
        let atomPattern = #"<entry[^>]*>([\s\S]*?)</entry>"#

        for pattern in [rssPattern, atomPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(xml.startIndex..., in: xml)
            for match in regex.matches(in: xml, options: [], range: range) {
                guard let blockRange = Range(match.range(at: 1), in: xml) else { continue }
                let block = String(xml[blockRange])
                let title = extract(#"<title[^>]*>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?</title>"#, from: block)
                var link = extract(#"<link[^>]*href="([^"]+)""#, from: block)
                if link.isEmpty {
                    link = extract(#"<link[^>]*>([\s\S]*?)</link>"#, from: block)
                }
                let cleanTitle = title
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanTitle.isEmpty {
                    items.append(Item(title: cleanTitle, link: link.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            if !items.isEmpty { break }
        }
        return items
    }

    private static func extract(_ pattern: String, from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return "" }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return "" }
        return String(text[valueRange])
    }
}

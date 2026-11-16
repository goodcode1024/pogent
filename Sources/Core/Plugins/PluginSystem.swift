import Foundation
import JavaScriptCore
import Observation
import SwiftData

// MARK: - 清单

struct PluginManifest: Codable, Sendable {
    struct ToolSpec: Codable, Sendable {
        var name: String
        var summary: String
        var risk: String
        var parameters: JSONValue?
    }

    var name: String
    var version: String
    var summary: String
    var author: String
    var entry: String
    var permissions: [String]
    var tools: [ToolSpec]
}

struct MarketplaceItem: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var summary: String
    var version: String
    var author: String
    var downloads: Int
    var source: String
    var tags: [String]
}

// MARK: - 运行时

/// 插件是纯 JavaScript：没有子进程、没有原生扩展。
/// 这和 Fish Pocket 的插件兼容策略一致 —— 能在 iOS 沙箱里跑的才装。
@MainActor
@Observable
final class PluginRuntime {
    private struct Loaded {
        var manifest: PluginManifest
        var context: JSContext
        var functions: [String: JSValue]
    }

    private var loaded: [String: Loaded] = [:]
    private(set) var errors: [String: String] = [:]

    func load(_ record: PluginRecord) {
        guard loaded[record.id] == nil else { return }
        guard let manifest = try? JSONDecoder().decode(PluginManifest.self, from: Data(record.manifestJSON.utf8)) else {
            errors[record.id] = "清单解析失败"
            return
        }

        let context = JSContext()!
        var functions: [String: JSValue] = [:]
        let register: @convention(block) (JSValue?, JSValue?) -> Void = { spec, handler in
            guard let spec, let handler, let name = spec.objectForKeyedSubscript("name")?.toString() else { return }
            functions[name] = handler
        }
        context.setObject(register, forKeyedSubscript: "pogentRegister" as NSString)

        let script = """
        var pogent = {
          registerTool: function(spec, handler) { pogentRegister(spec, handler); },
          log: function(message) { console.log(message); }
        };
        \(record.source)
        """
        context.evaluateScript(script)
        if let exception = context.exception {
            errors[record.id] = exception.toString() ?? "JS 异常"
            context.exception = nil
        }

        loaded[record.id] = Loaded(manifest: manifest, context: context, functions: functions)
    }

    func tools(for record: PluginRecord) -> [any AgentTool] {
        load(record)
        guard let entry = loaded[record.id] else { return [] }
        return entry.manifest.tools.compactMap { spec in
            guard let function = entry.functions[spec.name] else { return nil }
            return JavaScriptPluginTool(
                spec: spec,
                pluginName: entry.manifest.name,
                function: function,
                context: entry.context
            )
        }
    }

    func unload(_ id: String) {
        loaded[id] = nil
        errors[id] = nil
    }

    var count: Int { loaded.count }
}

@MainActor
final class JavaScriptPluginTool: AgentTool {
    let definition: ToolDefinition
    private let function: JSValue
    private let context: JSContext

    init(spec: PluginManifest.ToolSpec, pluginName: String, function: JSValue, context: JSContext) {
        self.function = function
        self.context = context
        let risk = RiskLevel(rawValue: ["safe": 0, "sensitive": 1, "destructive": 2, "financial": 3][spec.risk] ?? 1) ?? .sensitive
        self.definition = ToolDefinition(
            name: "\(pluginName).\(spec.name)".replacingOccurrences(of: " ", with: "_"),
            summary: "[插件] \(spec.summary)",
            surface: .shell,
            risk: risk,
            parameters: spec.parameters ?? .jsonSchema(properties: [:])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let input = arguments.compactDescription
        guard let result = function.call(withArguments: [input]) else {
            return .failed("插件没有返回结果")
        }
        if let exception = self.context.exception {
            self.context.exception = nil
            return .failed("插件报错：\(exception)")
        }
        if result.isString, let text = result.toString() {
            return .ok(String(text.prefix(200)), modelText: String(text.prefix(8000)))
        }
        if let object = result.toObject() as? [String: Any] {
            let summary = object["summary"] as? String ?? "插件执行完成"
            let text = object["text"] as? String ?? summary
            return .ok(summary, modelText: text)
        }
        return .ok(result.toString() ?? "插件执行完成")
    }
}

// MARK: - 市场

@MainActor
@Observable
final class MarketplaceClient {
    private(set) var items: [MarketplaceItem] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    var indexURL = URL(string: "https://plugins.pogent.bot/index.json")!

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: indexURL)
            items = try JSONDecoder().decode([MarketplaceItem].self, from: data)
        } catch {
            lastError = error.localizedDescription
            // 离线时给一份内置示例，界面不至于空着。
            if items.isEmpty { items = Self.bundled }
        }
    }

    static let bundled: [MarketplaceItem] = [
        .init(id: "safety-net", name: "cc-safety-net", summary: "拦截 git reset --hard、rm -rf 这类危险命令，装完立即生效。",
              version: "1.4.0", author: "community", downloads: 12800, source: "npm", tags: ["安全"]),
        .init(id: "pdf-kit", name: "pdf-kit", summary: "拆分、合并、盖章、抽表格，全部在本机完成。",
              version: "2.1.3", author: "community", downloads: 9400, source: "npm", tags: ["文档"]),
        .init(id: "sheet-bridge", name: "sheet-bridge", summary: "读写 xlsx / csv，按模板生成月报。",
              version: "0.9.8", author: "community", downloads: 6100, source: "npm", tags: ["表格"]),
        .init(id: "wechat-helper", name: "wechat-helper", summary: "给微信操作加上确认与合并窗口，避免误发。",
              version: "1.0.2", author: "community", downloads: 4300, source: "npm", tags: ["自动化"])
    ]
}

// MARK: - 安装

@MainActor
final class PluginInstaller {
    private let workspace: URL
    private let runtime: PluginRuntime

    init(workspace: URL, runtime: PluginRuntime) {
        self.workspace = workspace
        self.runtime = runtime
    }

    func install(manifest: PluginManifest, source: String, context: ModelContext) throws -> PluginRecord {
        let directory = workspace.appendingPathComponent("plugins/\(manifest.name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestJSON = String(data: (try? encoder.encode(manifest)) ?? Data(), encoding: .utf8) ?? "{}"

        let record = PluginRecord(
            name: manifest.name,
            version: manifest.version,
            source: source,
            summary: manifest.summary,
            manifestJSON: manifestJSON
        )
        record.source = source
        context.insert(record)
        try context.save()
        runtime.load(record)
        return record
    }
}

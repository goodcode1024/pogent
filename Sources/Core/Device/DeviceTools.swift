import Foundation

// MARK: - 读屏

@MainActor
final class LookTool: AgentTool {
    private let control: DeviceControlService

    init(control: DeviceControlService) { self.control = control }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "look",
            summary: "读取当前屏幕：App、元素树、可选截图。返回带稳定编号的元素，供 do 指代。",
            surface: .ui,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "full": .boolParam("true 时列出全部元素；默认只列可交互元素"),
                "include_screenshot": .boolParam("是否附带截图（默认 true）")
            ]),
            requiresForeground: true
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let full = arguments["full"]?.boolValue ?? false
        let includeShot = arguments["include_screenshot"]?.boolValue ?? true
        let snapshot = try await control.look(full: full)

        var lines: [String] = [
            "App: \(snapshot.appName) (\(snapshot.bundleID))",
            "屏幕: \(Int(snapshot.screenSize.width))×\(Int(snapshot.screenSize.height))，\(snapshot.isLocked ? "已锁屏" : "已解锁")",
            ""
        ]

        let visible = full ? snapshot.elements : snapshot.elements.filter { !$0.actions.isEmpty || $0.role == "text" }
        for element in visible.prefix(140) {
            let actions = element.actions.isEmpty ? "" : " [\(element.actions.joined(separator: ","))]"
            let value = element.value.map { " 值=\($0.prefix(30))" } ?? ""
            lines.append("\(element.shortDescription)\(value)\(actions)")
        }
        if let diff = control.lastDiff {
            lines.append("")
            lines.append("与上一次读屏相比：\(diff.summary)")
        }

        var payload: [String: JSONValue] = [
            "app": .string(snapshot.appName),
            "bundle_id": .string(snapshot.bundleID),
            "element_count": .number(Double(snapshot.elements.count)),
            "text": .string(lines.joined(separator: "\n"))
        ]
        if includeShot, let data = snapshot.screenshotJPEG {
            payload["screenshot_base64"] = .string(data.base64EncodedString())
        }

        context.recordActivity("读取 \(snapshot.appName) 的屏幕")
        return .ok("已读取 \(snapshot.appName)", payload: .object(payload), modelText: lines.joined(separator: "\n"))
    }
}

// MARK: - 执行

@MainActor
final class DoTool: AgentTool {
    private let control: DeviceControlService
    private let ledger: AuditLedger

    init(control: DeviceControlService, ledger: AuditLedger) {
        self.control = control
        self.ledger = ledger
    }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "do",
            summary: "依次执行界面动作，然后重新读屏。一次最多 12 个动作；高风险动作会先征得同意。",
            surface: .ui,
            risk: .sensitive,
            parameters: .jsonSchema(
                properties: [
                    "actions": .arrayParam("动作数组，元素用 look 返回的编号"),
                    "finish": .boolParam("任务结束时为 true：切回发起任务的 App"),
                    "full": .boolParam("读屏时是否返回全部元素")
                ],
                required: ["actions"]
            ),
            requiresForeground: true
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let rawActions = arguments["actions"]?.arrayValue, !rawActions.isEmpty else {
            return .failed("actions 不能为空")
        }

        var actions: [ControlAction] = []
        for raw in rawActions {
            guard let action = Self.decode(raw) else {
                return .failed("看不懂的动作：\(raw.compactDescription)")
            }
            actions.append(action)
        }

        // 风险预判：付款、删除、发送消息、密码，都在真正点下去之前拦。
        if let risk = Self.assess(actions: actions, snapshot: control.lastSnapshot) {
            let request = ApprovalRequest(
                runID: context.runID,
                toolName: "do",
                title: risk.title,
                detail: actions.map(\.label).joined(separator: " → "),
                risk: risk.level,
                kind: risk.kind,
                appName: control.currentApp.ifEmpty(context.originApp)
            )
            let decision = await context.requestApproval(request)
            switch decision {
            case .allowed:
                break
            case .denied(let reason):
                return .denied(reason)
            case .expired:
                return .denied("等待太久，操作已取消，画面可能已经变化")
            case .handoff:
                return .needsHuman("这一步需要你本人完成", kind: "handoff")
            }
        }

        let (snapshot, diff) = try await control.perform(actions, finish: arguments["finish"]?.boolValue ?? false)

        let full = arguments["full"]?.boolValue ?? false
        let visible = full ? snapshot.elements : snapshot.elements.filter { !$0.actions.isEmpty }
        var lines = [
            "已执行 \(actions.count) 个动作：\(actions.map(\.label).joined(separator: " → "))",
            "现在在 \(snapshot.appName)，\(diff?.summary ?? "已重新读屏")"
        ]
        if !visible.isEmpty {
            lines.append("")
            for element in visible.prefix(80) {
                lines.append(element.shortDescription)
            }
        }
        if let diff, !diff.appeared.isEmpty {
            lines.append("")
            lines.append("新出现：\(diff.appeared.prefix(10).map(\.shortDescription).joined(separator: "，"))")
        }

        ledger.append(.init(
            kind: .toolCall,
            title: "界面动作",
            detail: actions.map(\.label).joined(separator: " → "),
            risk: .sensitive,
            runID: context.runID
        ))

        return .ok("在 \(snapshot.appName) 执行了 \(actions.count) 个动作", payload: .object([
            "app": .string(snapshot.appName),
            "screen_changed": .bool(diff?.isEmpty == false)
        ]), modelText: lines.joined(separator: "\n"))
    }

    // MARK: 解码

    static func decode(_ raw: JSONValue) -> ControlAction? {
        guard let type = raw["type"]?.stringValue else { return nil }
        switch type {
        case "tap":
            if let id = raw["element"]?.intValue { return .tap(element: id) }
            if let x = raw["x"]?.doubleValue, let y = raw["y"]?.doubleValue { return .tapPoint(x: x, y: y) }
            return nil
        case "long_press":
            guard let id = raw["element"]?.intValue else { return nil }
            return .longPress(element: id, seconds: raw["seconds"]?.doubleValue ?? 0.8)
        case "type":
            guard let text = raw["text"]?.stringValue else { return nil }
            return .typeText(text, element: raw["element"]?.intValue)
        case "key":
            guard let key = raw["key"]?.stringValue else { return nil }
            return .pressKey(key)
        case "swipe":
            return .swipe(
                fromX: raw["from_x"]?.doubleValue ?? 0.5,
                fromY: raw["from_y"]?.doubleValue ?? 0.7,
                toX: raw["to_x"]?.doubleValue ?? 0.5,
                toY: raw["to_y"]?.doubleValue ?? 0.3,
                duration: raw["duration"]?.doubleValue ?? 0.3
            )
        case "scroll":
            guard let id = raw["element"]?.intValue else { return nil }
            return .scroll(element: id, direction: raw["direction"]?.stringValue ?? "down", pages: raw["pages"]?.doubleValue ?? 1)
        case "drag":
            guard let from = raw["from"]?.intValue, let to = raw["to"]?.intValue else { return nil }
            return .drag(fromElement: from, toElement: to)
        case "launch":
            guard let bundle = raw["bundle_id"]?.stringValue ?? raw["app"]?.stringValue.flatMap(AppCatalog.bundleID(for:)) else { return nil }
            return .launch(bundleID: bundle)
        case "home": return .home
        case "back": return .back
        case "wait": return .wait(seconds: raw["seconds"]?.doubleValue ?? 1)
        case "run":
            guard let name = raw["name"]?.stringValue else { return nil }
            var values: [String: String] = [:]
            for (key, value) in raw["with"]?.objectValue ?? [:] {
                if let text = value.stringValue { values[key] = text }
            }
            return .runRoutine(name: name, values: values)
        default: return nil
        }
    }

    // MARK: 风险判断

    struct RiskHint { var level: RiskLevel; var kind: ApprovalRequest.Kind; var title: String }

    static func assess(actions: [ControlAction], snapshot: ScreenSnapshot?) -> RiskHint? {
        var hint: RiskHint?
        for action in actions {
            switch action {
            case .tap(let id), .longPress(let id, _), .drag(_, let id):
                guard let element = snapshot?.element(id) else { continue }
                let text = (element.label + " " + (element.value ?? "")).lowercased()
                if containsAny(text, ["支付", "付款", "确认付款", "转账", "pay", "buy", "purchase"]) {
                    hint = RiskHint(level: .financial, kind: .payment, title: "确认付款")
                } else if containsAny(text, ["删除", "清空", "移除", "delete", "remove", "trash"]) {
                    hint = RiskHint(level: .destructive, kind: .deletion, title: "确认删除")
                } else if containsAny(text, ["发送", "发表", "send", "post"]) {
                    hint = RiskHint(level: .sensitive, kind: .message, title: "确认发送")
                }
            case .typeText(_, let elementID):
                if let elementID, let element = snapshot?.element(elementID), element.isSecure {
                    hint = RiskHint(level: .financial, kind: .password, title: "需要本人输入密码")
                }
            case .pressKey(let key):
                if key == "return", snapshot?.appName.contains("微信") == true {
                    hint = RiskHint(level: .sensitive, kind: .message, title: "确认发送")
                }
            case .launch(let bundleID):
                if bundleID == "com.apple.Passbook" {
                    hint = RiskHint(level: .financial, kind: .wallet, title: "Wallet 操作")
                }
            default:
                continue
            }
        }
        return hint
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}

// MARK: - 打开 App

@MainActor
final class LaunchAppTool: AgentTool {
    private let control: DeviceControlService

    init(control: DeviceControlService) { self.control = control }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "launch_app",
            summary: "按名称或 bundle id 打开一个 App，并读取它的屏幕。",
            surface: .ui,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "app": .stringParam("App 名称，例如 日历 / 微信 / 美团")
            ], required: ["app"]),
            requiresForeground: true
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let name = arguments["app"]?.stringValue else { return .failed("缺少 app") }
        guard let bundleID = AppCatalog.bundleID(for: name) else {
            return .failed("没有找到「\(name)」，可用：\(AppCatalog.knownNames.prefix(12).joined(separator: "、"))")
        }
        let (snapshot, _) = try await control.perform([.launch(bundleID: bundleID)])
        return .ok("已打开 \(snapshot.appName)", payload: .object([
            "app": .string(snapshot.appName),
            "bundle_id": .string(bundleID)
        ]))
    }
}

// MARK: - App 目录

enum AppCatalog {
    static let map: [String: String] = [
        "日历": "com.apple.mobilecal",
        "提醒事项": "com.apple.reminders",
        "备忘录": "com.apple.mobilenotes",
        "信息": "com.apple.MobileSMS",
        "邮件": "com.apple.mobilemail",
        "地图": "com.apple.Maps",
        "照片": "com.apple.mobileslideshow",
        "设置": "com.apple.Preferences",
        "健康": "com.apple.Health",
        "钱包": "com.apple.Passbook",
        "音乐": "com.apple.Music",
        "计算器": "com.apple.calculator",
        "微信": "com.tencent.xin",
        "支付宝": "com.alipay.iphoneclient",
        "美团": "com.meituan.imeituan",
        "淘宝": "com.taobao.taobao4iphone",
        "小红书": "com.xingin.discover",
        "抖音": "com.ss.iphone.ugc.Aweme",
        "高德地图": "com.autonavi.amap",
        "钉钉": "com.laiwang.DingTalk"
    ]

    static var knownNames: [String] { Array(map.keys).sorted() }

    static func bundleID(for name: String) -> String? {
        if map[name] != nil { return map[name] }
        let lowered = name.lowercased()
        return map.first { $0.key.lowercased() == lowered || $0.value.lowercased() == lowered }?.value
    }
}

extension String {
    func ifEmpty(_ fallback: String?) -> String {
        isEmpty ? (fallback ?? "") : self
    }
}

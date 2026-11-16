import Foundation
import Observation

// MARK: - 屏幕元素

struct AutomationElement: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var role: String
    var label: String
    var value: String?
    var identifier: String?
    var frame: CGRect
    var isEnabled: Bool
    var isSelected: Bool
    var isSecure: Bool
    var actions: [String]

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    var shortDescription: String {
        let text = label.isEmpty ? (value ?? identifier ?? role) : label
        return "#\(id) \(role) \"\(text.prefix(40))\""
    }
}

struct ScreenSnapshot: Codable, Sendable {
    var bundleID: String
    var appName: String
    var capturedAt: Date
    var screenSize: CGSize
    var isLocked: Bool
    var elements: [AutomationElement]
    var screenshotJPEG: Data?
    var screenshotScale: Double
    var scrollPosition: String?

    func element(_ id: Int) -> AutomationElement? {
        elements.first { $0.id == id }
    }
}

struct ScreenDiff: Sendable {
    var appeared: [AutomationElement]
    var changed: [AutomationElement]
    var disappeared: [Int]
    var textChanged: Bool
    var imageChanged: Bool

    var isEmpty: Bool { appeared.isEmpty && changed.isEmpty && disappeared.isEmpty && !imageChanged }

    var summary: String {
        var parts: [String] = []
        if !appeared.isEmpty { parts.append("新增 \(appeared.count) 个元素") }
        if !changed.isEmpty { parts.append("\(changed.count) 个元素变化") }
        if !disappeared.isEmpty { parts.append("\(disappeared.count) 个元素消失") }
        if imageChanged && parts.isEmpty { parts.append("画面变化") }
        return parts.isEmpty ? "画面未变" : parts.joined(separator: "，")
    }
}

// MARK: - 动作

enum ControlAction: Codable, Hashable, Sendable {
    case tap(element: Int)
    case tapPoint(x: Double, y: Double)
    case longPress(element: Int, seconds: Double)
    case typeText(String, element: Int?)
    case pressKey(String)
    case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double)
    case scroll(element: Int, direction: String, pages: Double)
    case drag(fromElement: Int, toElement: Int)
    case launch(bundleID: String)
    case home
    case back
    case wait(seconds: Double)
    case runRoutine(name: String, values: [String: String])

    var isSensitiveByNature: Bool {
        switch self {
        case .typeText, .pressKey: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .tap(let id): "点按 #\(id)"
        case .tapPoint(let x, let y): "点按坐标 (\(Int(x)), \(Int(y)))"
        case .longPress(let id, _): "长按 #\(id)"
        case .typeText(let text, _): "输入「\(text.prefix(24))」"
        case .pressKey(let key): "按键 \(key)"
        case .swipe: "滑动"
        case .scroll(_, let direction, _): "向\(direction)滚动"
        case .drag: "拖拽"
        case .launch(let bundle): "打开 \(bundle)"
        case .home: "回到主屏"
        case .back: "返回"
        case .wait(let seconds): "等待 \(seconds) 秒"
        case .runRoutine(let name, _): "运行例程 \(name)"
        }
    }
}

// MARK: - 传输层

enum AutomationError: LocalizedError {
    case unavailable
    case locked
    case busy
    case deadline
    case elementNotFound(Int)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "系统自动化服务不可用，请检查「pogent 操控手机」授权。"
        case .locked: "手机已锁屏，只能执行有限操作。"
        case .busy: "上一次操作还没结束。"
        case .deadline: "这一步超时，画面可能已经变化，建议重新读屏。"
        case .elementNotFound(let id): "找不到元素 #\(id)，请重新读屏。"
        case .failed(let reason): reason
        }
    }
}

/// iOS 27 只有一个执行后端：系统原生自动化服务。
/// 旧版本里那条 XCTest / WebDriverAgent 会话、10.7.0.1 隧道、独立 runner
/// 全部删掉了 —— 它们只在这一条路径之前存在。
@MainActor
protocol AutomationTransport: AnyObject {
    var isAvailable: Bool { get }
    func connect() async throws
    func snapshot(full: Bool) async throws -> ScreenSnapshot
    func perform(_ actions: [ControlAction]) async throws -> ScreenSnapshot
    func cancel()
}

// MARK: - 控件服务

@MainActor
@Observable
final class DeviceControlService {
    private let transport: any AutomationTransport

    private(set) var lastSnapshot: ScreenSnapshot?
    private(set) var isRunning = false
    private(set) var currentApp: String = ""
    private(set) var lastDiff: ScreenDiff?
    private(set) var elementNumbering: [String: Int] = [:]

    /// 任务开始时前台是哪个 App：结束时回到这里（Poki 的 origin-app 行为）。
    private(set) var originBundleID: String?
    private(set) var originAppName: String?

    private var nextElementID = 1
    private var lastElementKeys: [String: Int] = [:]

    var maxActionsPerCall = 12
    var actionDeadline: Duration = .seconds(25)

    init(transport: any AutomationTransport) {
        self.transport = transport
    }

    var isAvailable: Bool { transport.isAvailable }

    func beginTask() async throws {
        try await transport.connect()
        let snapshot = try await transport.snapshot(full: true)
        renumber(snapshot.elements)
        lastSnapshot = snapshot
        currentApp = snapshot.appName
        if originBundleID == nil {
            originBundleID = snapshot.bundleID
            originAppName = snapshot.appName
        }
    }

    func look(full: Bool = false) async throws -> ScreenSnapshot {
        let snapshot = try await transport.snapshot(full: full)
        let previous = lastSnapshot
        renumber(snapshot.elements, previous: previous?.elements ?? [])
        lastSnapshot = snapshot
        currentApp = snapshot.appName
        lastDiff = previous.map { diff(old: $0, new: snapshot) }
        return snapshot
    }

    func perform(_ actions: [ControlAction], finish: Bool = false) async throws -> (ScreenSnapshot, ScreenDiff?) {
        guard !actions.isEmpty else {
            let snapshot = try await look()
            return (snapshot, nil)
        }
        guard actions.count <= maxActionsPerCall else {
            throw AutomationError.failed("一次最多 \(maxActionsPerCall) 个动作，请拆分")
        }

        isRunning = true
        defer { isRunning = false }

        let previous = lastSnapshot
        let snapshot = try await transport.perform(actions)
        renumber(snapshot.elements, previous: previous?.elements ?? [])
        lastSnapshot = snapshot
        currentApp = snapshot.appName

        let screenDiff: ScreenDiff? = previous.map { (old: ScreenSnapshot) in
            self.diff(old: old, new: snapshot)
        }
        lastDiff = screenDiff

        if finish { try? await restoreOrigin() }
        return (snapshot, diff)
    }

    func restoreOrigin() async throws {
        guard let originBundleID, originBundleID != lastSnapshot?.bundleID else { return }
        _ = try await transport.perform([.launch(bundleID: originBundleID)])
    }

    func stop() {
        transport.cancel()
        isRunning = false
    }

    // MARK: 元素编号稳定化

    /// 元素编号跨两次读屏保持不变，模型才能用 #12 指代同一个按钮。
    private func renumber(_ elements: [AutomationElement], previous: [AutomationElement] = []) {
        var keys = lastElementKeys
        for element in previous {
            keys[Self.key(for: element)] = element.id
        }
        for element in elements {
            let key = Self.key(for: element)
            if let existing = keys[key] {
                elementNumbering[key] = existing
            } else {
                keys[key] = nextElementID
                elementNumbering[key] = nextElementID
                nextElementID += 1
            }
        }
        lastElementKeys = keys
    }

    func displayID(for element: AutomationElement) -> Int {
        elementNumbering[Self.key(for: element)] ?? element.id
    }

    private static func key(for element: AutomationElement) -> String {
        let identity = element.identifier ?? element.label
        let cell = "\(Int(element.frame.minX / 8)):\(Int(element.frame.minY / 8))"
        return "\(element.role)|\(identity)|\(cell)"
    }

    private func diff(old: ScreenSnapshot, new: ScreenSnapshot) -> ScreenDiff {
        let oldMap = Dictionary(uniqueKeysWithValues: old.elements.map { (Self.key(for: $0), $0) })
        let newMap = Dictionary(uniqueKeysWithValues: new.elements.map { (Self.key(for: $0), $0) })

        let appeared = new.elements.filter { oldMap[Self.key(for: $0)] == nil }
        let disappeared = old.elements.filter { newMap[Self.key(for: $0)] == nil }.map(\.id)
        let changed = new.elements.filter { element in
            guard let before = oldMap[Self.key(for: element)] else { return false }
            return before.value != element.value || before.label != element.label || before.isEnabled != element.isEnabled
        }

        let textChanged = appeared.isEmpty == false || !changed.isEmpty
        let imageChanged = old.screenshotJPEG != new.screenshotJPEG

        return ScreenDiff(
            appeared: appeared,
            changed: changed,
            disappeared: disappeared,
            textChanged: textChanged,
            imageChanged: imageChanged
        )
    }
}

// MARK: - 系统服务适配器

/// 这一层就是 iOS 27 native services 的落点。
///
/// 旧实现（已删除，不再编译）：
///   - `XCTestSession` 连接 WebDriverAgent，走 `127.0.0.1:8100`
///   - `PokiTunnel` 把 `10.7.0.1` 转发到本机回环，需要用户装 VPN
///   - 单独的 `PokiLauncher` runner 保活
///
/// 现在只有一条 `AutomationRequest` 通道，请求体是 JSON，
/// 由系统服务完成读屏、合成触摸事件、返回新的元素树。
/// 接入时需要把 `send(_:)` 换成真正的 XPC / entitlement 通道。
@MainActor
final class SystemAutomationTransport: AutomationTransport {
    struct AutomationRequest: Codable {
        enum Op: String, Codable { case connect, snapshot, perform, cancel }
        var op: Op
        var full: Bool?
        var actions: [ControlAction]?
        var taskID: String?
    }

    struct AutomationResponse: Codable {
        var snapshot: ScreenSnapshot?
        var error: String?
    }

    private var sessionID: String?
    private var connected = false

    var isAvailable: Bool { true }

    func connect() async throws {
        guard !connected else { return }
        let response = try await send(AutomationRequest(op: .connect))
        if let error = response.error { throw AutomationError.failed(error) }
        connected = true
        sessionID = UUID().uuidString
    }

    func snapshot(full: Bool) async throws -> ScreenSnapshot {
        try await connect()
        let response = try await send(AutomationRequest(op: .snapshot, full: full, taskID: sessionID))
        if let error = response.error { throw AutomationError.failed(error) }
        guard let snapshot = response.snapshot else { throw AutomationError.failed("系统没有返回画面") }
        return snapshot
    }

    func perform(_ actions: [ControlAction]) async throws -> ScreenSnapshot {
        try await connect()
        let response = try await send(AutomationRequest(op: .perform, actions: actions, taskID: sessionID))
        if let error = response.error { throw AutomationError.failed(error) }
        guard let snapshot = response.snapshot else { throw AutomationError.failed("动作已发送，但没有拿到新画面") }
        return snapshot
    }

    func cancel() {
        Task { _ = try? await send(AutomationRequest(op: .cancel, taskID: sessionID)) }
        connected = false
        sessionID = nil
    }

    // MARK: 通道

    /// iOS 27 原生自动化服务的唯一出入口。
    /// 生产实现：`NSXPCConnection(machServiceName: "com.apple.automation.agent")`，
    /// 或 App 内 `AutomationSession`（系统框架提供）。协议两端都用上面的 JSON 结构。
    private func send(_ request: AutomationRequest) async throws -> AutomationResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        _ = try encoder.encode(request)

        // 接入点：把下面这行替换为真实通道调用。
        // let reply = try await AutomationSession.shared.call(payload)
        throw AutomationError.unavailable
    }
}

import Foundation

/// 演示用传输层：没有系统自动化授权时，让 App 在模拟器里也能走完整流程。
/// 它不点真正的 App，只在一个假界面上移动高亮，用来验证 UI 和审批链路。
@MainActor
final class DemoAutomationTransport: AutomationTransport {
    var isAvailable: Bool { true }

    private var app = "日历"
    private var bundle = "com.apple.mobilecal"
    private var selected: Int?
    private var screen = 0

    func connect() async throws {}

    func snapshot(full: Bool) async throws -> ScreenSnapshot {
        let elements = Self.elements(for: app, screen: screen, selected: selected)
        return ScreenSnapshot(
            bundleID: bundle,
            appName: app,
            capturedAt: Date(),
            screenSize: CGSize(width: 393, height: 852),
            isLocked: false,
            elements: elements,
            screenshotJPEG: nil,
            screenshotScale: 3,
            scrollPosition: nil
        )
    }

    func perform(_ actions: [ControlAction]) async throws -> ScreenSnapshot {
        for action in actions {
            switch action {
            case .launch(let bundleID):
                bundle = bundleID
                app = AppCatalog.map.first { $0.value == bundleID }?.key ?? "App"
                selected = nil
                screen = 0
            case .tap(let id):
                selected = id
                screen += 1
            case .tapPoint:
                screen += 1
            case .typeText:
                break
            case .home:
                app = "主屏幕"
                bundle = "com.apple.springboard"
                selected = nil
            default:
                break
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return try await snapshot(full: true)
    }

    func cancel() {}

    private static func elements(for app: String, screen: Int, selected: Int?) -> [AutomationElement] {
        var items: [AutomationElement] = [
            AutomationElement(id: 1, role: "window", label: app, value: nil, identifier: "root",
                              frame: CGRect(x: 0, y: 0, width: 393, height: 852), isEnabled: true,
                              isSelected: false, isSecure: false, actions: []),
            AutomationElement(id: 2, role: "button", label: "返回", value: nil, identifier: "nav.back",
                              frame: CGRect(x: 12, y: 60, width: 44, height: 44), isEnabled: true,
                              isSelected: false, isSecure: false, actions: ["tap"]),
            AutomationElement(id: 3, role: "button", label: "完成", value: nil, identifier: "nav.done",
                              frame: CGRect(x: 330, y: 60, width: 52, height: 44), isEnabled: true,
                              isSelected: false, isSecure: false, actions: ["tap"])
        ]

        let rows: [(String, String, CGRect, String)] = [
            ("今天", "3 个日程", CGRect(x: 16, y: 140, width: 361, height: 72), "row.today"),
            ("明天", "牙医 15:00", CGRect(x: 16, y: 224, width: 361, height: 72), "row.tomorrow"),
            ("本周", "5 个日程", CGRect(x: 16, y: 308, width: 361, height: 72), "row.week")
        ]

        for (index, row) in rows.enumerated() {
            items.append(AutomationElement(
                id: 10 + index, role: "cell", label: row.0, value: row.1, identifier: row.3,
                frame: row.2, isEnabled: true, isSelected: selected == 10 + index,
                isSecure: false, actions: ["tap"]
            ))
        }

        if screen > 0 {
            items.append(AutomationElement(
                id: 20, role: "textfield", label: "标题", value: "牙医", identifier: "editor.title",
                frame: CGRect(x: 16, y: 420, width: 361, height: 44), isEnabled: true,
                isSelected: false, isSecure: false, actions: ["tap", "set_value"]
            ))
            items.append(AutomationElement(
                id: 21, role: "button", label: "保存", value: nil, identifier: "editor.save",
                frame: CGRect(x: 300, y: 780, width: 77, height: 44), isEnabled: true,
                isSelected: false, isSecure: false, actions: ["tap"]
            ))
        }

        return items
    }
}

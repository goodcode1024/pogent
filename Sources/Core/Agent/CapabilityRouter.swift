import Foundation

/// 三层能力路由：同一件事往往有三种做法，先选最稳的那一种。
///
///   系统能力  →  本机运行时  →  界面操控
///   native       shell          ui
///
/// 举个例子：「把明天下午三点的牙医预约加到日历」
///   native: calendar(action:create)          ✅ 一步完成
///   shell:  写个 ics 再导入                   ❌ 没必要
///   ui:     打开日历 → 点 + → 填表 → 保存     ❌ 慢且易错
///
/// 「把这个月的账单截图整理成表格」
///   native: 不行（数据在别的 App 里）
///   shell:  可以（文件 + python）
///   ui:     需要先读屏拿数据
struct CapabilityRouter {

    struct Route: Identifiable {
        let id = UUID()
        var surface: ExecutionSurface
        var rationale: String
        var suggestedTools: [String]
    }

    func routes(for task: String) -> [Route] {
        let lowered = task.lowercased()
        var routes: [Route] = []

        if containsAny(lowered, ["日历", "日程", "提醒", "闹钟", "健康", "步数", "照片", "联系人", "导航", "路线", "家庭", "灯", "空调", "剪贴板", "通知"]) {
            routes.append(Route(
                surface: .native,
                rationale: "这类数据有系统 API，直接读写最可靠，也不受界面改版影响。",
                suggestedTools: ["calendar", "reminders", "health", "photos", "contacts", "maps", "home", "clipboard", "notify"]
            ))
        }

        if containsAny(lowered, ["表格", "excel", "csv", "脚本", "批量", "重命名", "转码", "视频", "图片处理", "git", "代码", "爬", "整理文件"]) {
            routes.append(Route(
                surface: .shell,
                rationale: "涉及文件和多步计算，交给终端与运行时，结果可复现。",
                suggestedTools: ["shell", "read_file", "write_file", "git", "media"]
            ))
        }

        if containsAny(lowered, ["微信", "美团", "淘宝", "小红书", "抖音", "支付宝", "外卖", "下单", "点餐", "订票", "小程序"]) {
            routes.append(Route(
                surface: .ui,
                rationale: "这些 App 没有开放接口，只能读屏 + 点按。先 look 再 do，每一步都核对画面。",
                suggestedTools: ["look", "do", "launch_app"]
            ))
        }

        if routes.isEmpty {
            routes = [
                Route(surface: .native, rationale: "先看系统能力能不能直接办。", suggestedTools: ["calendar", "reminders", "contacts", "photos"]),
                Route(surface: .shell, rationale: "需要计算或文件时用运行时。", suggestedTools: ["shell", "read_file", "write_file"]),
                Route(surface: .ui, rationale: "最后才操作界面。", suggestedTools: ["look", "do"])
            ]
        }

        return routes.sorted { $0.surface.priority < $1.surface.priority }
    }

    /// 少给模型一些工具，选择会更准，也更省 token。
    func prune(_ definitions: [ToolDefinition], for task: String) -> [ToolDefinition] {
        let routes = routes(for: task)
        let allowed = Set(routes.flatMap(\.suggestedTools))
        let filtered = definitions.filter { allowed.contains($0.name) || $0.name == "web_fetch" }
        return filtered.isEmpty ? definitions : filtered
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}

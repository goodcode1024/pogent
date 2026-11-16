import Foundation
import AppIntents

/// 控制中心 / 锁屏控件用：一键打开 pogent 开始说话。
struct OpenPogentIntent: AppIntent {
    static var title: LocalizedStringResource { "问 pogent" }
    static var description: IntentDescription { IntentDescription("打开 pogent，直接开始一个任务。") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "任务")
    var task: String?

    init() {}

    init(task: String?) {
        self.task = task
    }

    func perform() async throws -> some IntentResult {
        if let task, !task.isEmpty {
            UserDefaults(suiteName: "group.bot.pogent")?.set(task, forKey: "pendingTask")
        }
        return .result()
    }
}

/// 给控制中心按钮用的一句话指令。
struct QuickTaskIntent: AppIntent {
    static var title: LocalizedStringResource { "交给 pogent" }
    static var description: IntentDescription { IntentDescription("把一段文字交给 pogent 执行。") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "内容")
    var text: String

    init() {}

    init(text: String) {
        self.text = text
    }

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: "group.bot.pogent")?.set(text, forKey: "pendingTask")
        return .result()
    }
}

import Foundation
import SwiftData
import Observation
import UserNotifications

/// Bot 团队：每个 Bot 有自己的形象、人设、记忆和工作目录。
/// 可以私聊、拉群、定时开工。执行仍然走同一个 AgentRuntime。
@MainActor
@Observable
final class BotCoordinator {
    struct Room: Identifiable {
        var id: String = UUID().uuidString
        var title: String
        var botIDs: [String]
    }

    private(set) var bots: [BotProfile] = []
    private(set) var rooms: [Room] = []
    private(set) var runningBotID: String?

    private let context: ModelContext
    private let runtime: AgentRuntime

    init(context: ModelContext, runtime: AgentRuntime) {
        self.context = context
        self.runtime = runtime
        load()
    }

    func load() {
        let descriptor = FetchDescriptor<BotProfile>(sortBy: [SortDescriptor(\.createdAt)])
        bots = (try? context.fetch(descriptor)) ?? []
        if bots.isEmpty {
            let defaults = [
                BotProfile(name: "大肥鱼", symbol: "fish.fill", colorHex: "#5EEAD4",
                           persona: "你叫大肥鱼，做事利索，说话简短，先给结论再给细节。",
                           workingDirectory: "bots/fish"),
                BotProfile(name: "小账本", symbol: "yensign.circle.fill", colorHex: "#FBBF24",
                           persona: "你负责记账和账单核对，数字必须准确，不确定就说不确定。",
                           workingDirectory: "bots/ledger"),
                BotProfile(name: "查资料", symbol: "magnifyingglass.circle.fill", colorHex: "#A78BFA",
                           persona: "你负责查资料，给出来源链接，区分事实和推测。",
                           workingDirectory: "bots/research")
            ]
            defaults.forEach { context.insert($0) }
            try? context.save()
            bots = defaults
        }
    }

    func create(name: String, symbol: String, colorHex: String, persona: String) -> BotProfile {
        let bot = BotProfile(name: name, symbol: symbol, colorHex: colorHex, persona: persona,
                             workingDirectory: "bots/\(name.lowercased())")
        context.insert(bot)
        try? context.save()
        bots.append(bot)
        return bot
    }

    func createRoom(title: String, botIDs: [String]) -> Room {
        let room = Room(title: title, botIDs: botIDs)
        rooms.append(room)
        return room
    }

    /// 给一个 Bot 派活。每个 Bot 有自己的系统提示词，工具集完全相同。
    func dispatch(_ prompt: String, to bot: BotProfile, conversation: Conversation, modelContext: ModelContext) async {
        runningBotID = bot.id
        defer { runningBotID = nil }

        let message = """
        [来自 Bot：\(bot.name)]
        \(bot.persona)

        记忆：
        \(bot.memory.isEmpty ? "（暂无）" : bot.memory)

        任务：\(prompt)
        """
        await runtime.submit(message, conversation: conversation, context: modelContext)

        // 简单记忆：把这次的任务记下来，下次一起带上。
        bot.memory = String((bot.memory + "\n- " + prompt).suffix(1200))
        try? modelContext.save()
    }

    /// 群里 @ 谁，谁先答；都没 @ 就让第一个 Bot 先答，其余补充。
    func dispatchToRoom(_ prompt: String, room: Room, conversation: Conversation, modelContext: ModelContext) async {
        let mentioned = bots.filter { bot in prompt.contains("@\(bot.name)") }
        let responders = mentioned.isEmpty ? Array(bots.filter { room.botIDs.contains($0.id) }.prefix(2)) : mentioned
        for bot in responders {
            await dispatch(prompt, to: bot, conversation: conversation, modelContext: modelContext)
        }
    }
}

/// 定时任务：每天/每周固定时间让某个 Bot 开工。
@MainActor
final class BotScheduler {
    struct Job: Codable, Identifiable {
        var id: String = UUID().uuidString
        var botID: String
        var prompt: String
        var hour: Int
        var minute: Int
        var weekdays: [Int]  // 1 = 周日
        var isEnabled: Bool = true
    }

    private(set) var jobs: [Job] = []
    private let fileURL: URL
    private let center = UNUserNotificationCenter.current()

    init(workspace: URL) {
        fileURL = workspace.appendingPathComponent("bot-jobs.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Job].self, from: data) {
            jobs = decoded
        }
    }

    func add(_ job: Job) async {
        jobs.append(job)
        persist()
        await scheduleNotification(for: job)
    }

    func remove(_ id: String) {
        jobs.removeAll { $0.id == id }
        center.removePendingNotificationRequests(withIdentifiers: ["job-\(id)"])
        persist()
    }

    private func scheduleNotification(for job: Job) async {
        let content = UNMutableNotificationContent()
        content.title = "pogent · Bot 开工"
        content.body = String(job.prompt.prefix(60))
        content.sound = .default

        var components = DateComponents()
        components.hour = job.hour
        components.minute = job.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "job-\(job.id)", content: content, trigger: trigger)
        try? await center.add(request)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(jobs) {
            try? data.write(to: fileURL)
        }
    }
}

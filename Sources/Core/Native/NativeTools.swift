import Foundation
@preconcurrency import EventKit
import Contacts

// MARK: - 权限

enum CapabilityPermission {
    static func requestCalendar() async throws {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw ToolError.permissionDenied("日历") }
    }

    static func requestReminders() async throws {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw ToolError.permissionDenied("提醒事项") }
    }

    static func requestContacts() async throws {
        let store = CNContactStore()
        let granted = try await store.requestAccess(for: .contacts)
        guard granted else { throw ToolError.permissionDenied("联系人") }
    }
}

enum ToolError: LocalizedError {
    case permissionDenied(String)
    case badInput(String)
    case unavailable(String)
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let name): "没有「\(name)」权限，请在 设置 → pogent → 本机能力 里打开。"
        case .badInput(let reason): "参数不对：\(reason)"
        case .unavailable(let reason): reason
        case .underlying(let reason): reason
        }
    }
}

enum DateParsing {
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd", "MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }

        if let seconds = Double(raw) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    static func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 日历

@MainActor
final class CalendarTool: AgentTool {
    private let store = EKEventStore()

    var definition: ToolDefinition {
        ToolDefinition(
            name: "calendar",
            summary: "查日程、建日程、找空闲时间。action=list/create/free_slots。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("list | create | free_slots"),
                "title": .stringParam("日程标题（create 必填）"),
                "start": .stringParam("开始时间，ISO8601 或 yyyy-MM-dd HH:mm"),
                "end": .stringParam("结束时间"),
                "duration_minutes": .numberParam("时长，默认 60"),
                "location": .stringParam("地点"),
                "notes": .stringParam("备注"),
                "days": .numberParam("list / free_slots 向后看几天，默认 7")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        try await CapabilityPermission.requestCalendar()
        let action = arguments["action"]?.stringValue ?? "list"

        switch action {
        case "list":
            let days = arguments["days"]?.intValue ?? 7
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? Date()
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

            let lines = events.prefix(60).map { event in
                "\(DateParsing.string(event.startDate))–\(DateFormatter.localizedString(from: event.endDate, dateStyle: .none, timeStyle: .short)) \(event.title ?? "(无标题)")\(event.location.map { " @\($0)" } ?? "")"
            }
            return .ok("未来 \(days) 天有 \(events.count) 个日程", payload: .object(["count": .number(Double(events.count))]),
                       modelText: lines.isEmpty ? "未来 \(days) 天没有日程。" : lines.joined(separator: "\n"))

        case "create":
            guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
                throw ToolError.badInput("create 需要 title")
            }
            guard let start = DateParsing.date(arguments["start"]?.stringValue) else {
                throw ToolError.badInput("create 需要 start")
            }
            let duration = TimeInterval((arguments["duration_minutes"]?.intValue ?? 60) * 60)
            let end = DateParsing.date(arguments["end"]?.stringValue) ?? start.addingTimeInterval(duration)

            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.location = arguments["location"]?.stringValue
            event.notes = arguments["notes"]?.stringValue
            event.calendar = store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first

            try store.save(event, span: .thisEvent, commit: true)
            return .ok("已加入日历：\(title) \(DateParsing.string(start))", payload: .object([
                "event_id": .string(event.eventIdentifier ?? ""),
                "title": .string(title)
            ]))

        case "free_slots":
            let days = arguments["days"]?.intValue ?? 7
            let slots = findFreeSlots(days: days, duration: TimeInterval((arguments["duration_minutes"]?.intValue ?? 60) * 60))
            let lines = slots.prefix(12).map { "\(DateParsing.string($0.lowerBound)) – \(DateFormatter.localizedString(from: $0.upperBound, dateStyle: .none, timeStyle: .short))" }
            return .ok("找到 \(slots.count) 段空闲", modelText: lines.isEmpty ? "没有整块空闲。" : lines.joined(separator: "\n"))

        default:
            throw ToolError.badInput("未知 action：\(action)")
        }
    }

    private func findFreeSlots(days: Int, duration: TimeInterval) -> [ClosedRange<Date>] {
        let calendar = Calendar.current
        var results: [ClosedRange<Date>] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date())),
                  let workStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                  let workEnd = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: day) else { continue }
            let predicate = store.predicateForEvents(withStart: workStart, end: workEnd, calendars: nil)
            let busy = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            var cursor = workStart
            for event in busy {
                if event.startDate.timeIntervalSince(cursor) >= duration {
                    results.append(cursor...event.startDate)
                }
                cursor = max(cursor, event.endDate)
            }
            if workEnd.timeIntervalSince(cursor) >= duration {
                results.append(cursor...workEnd)
            }
        }
        return results
    }
}

// MARK: - 提醒事项

@MainActor
final class ReminderTool: AgentTool {
    private let store = EKEventStore()

    var definition: ToolDefinition {
        ToolDefinition(
            name: "reminders",
            summary: "建提醒、列提醒、勾选完成。action=create/list/complete。",
            surface: .native,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("create | list | complete"),
                "title": .stringParam("提醒内容"),
                "due": .stringParam("到期时间"),
                "list_name": .stringParam("清单名，默认用系统默认清单"),
                "query": .stringParam("complete 时按标题匹配")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        try await CapabilityPermission.requestReminders()
        let action = arguments["action"]?.stringValue ?? "list"

        switch action {
        case "create":
            guard let title = arguments["title"]?.stringValue else { throw ToolError.badInput("缺少 title") }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = store.defaultCalendarForNewReminders()
            if let due = DateParsing.date(arguments["due"]?.stringValue) {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: due
                )
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            try store.save(reminder, commit: true)
            return .ok("已建提醒：\(title)")

        case "list":
            let calendar = store.defaultCalendarForNewReminders()
            let predicate = store.predicateForReminders(in: calendar.map { [$0] })
            let reminders: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
            }
            let pending = reminders.filter { !$0.isCompleted }
            let lines = pending.prefix(50).map { reminder -> String in
                let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                return "• \(reminder.title ?? "")\(due.map { "（\(DateParsing.string($0))）" } ?? "")"
            }
            return .ok("有 \(pending.count) 条未完成提醒", modelText: lines.isEmpty ? "没有未完成提醒。" : lines.joined(separator: "\n"))

        case "complete":
            let query = arguments["query"]?.stringValue ?? arguments["title"]?.stringValue ?? ""
            let predicate = store.predicateForReminders(in: nil)
            let all: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
            }
            guard let match = all.first(where: { !$0.isCompleted && ($0.title ?? "").contains(query) }) else {
                return .failed("没有找到包含「\(query)」的未完成提醒")
            }
            match.isCompleted = true
            match.completionDate = Date()
            try store.save(match, commit: true)
            return .ok("已完成：\(match.title ?? "")")

        default:
            throw ToolError.badInput("未知 action：\(action)")
        }
    }
}

// MARK: - 联系人

@MainActor
final class ContactTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "contacts",
            summary: "搜索联系人，拿到电话、邮箱和生日。只读。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "query": .stringParam("姓名、昵称或号码片段")
            ], required: ["query"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        try await CapabilityPermission.requestContacts()
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            throw ToolError.badInput("缺少 query")
        }
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey,
                    CNContactEmailAddressesKey, CNContactBirthdayKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)

        let lines = contacts.prefix(12).map { contact -> String in
            let name = "\(contact.familyName)\(contact.givenName)"
            let phones = contact.phoneNumbers.map { $0.value.stringValue }.joined(separator: " / ")
            let emails = contact.emailAddresses.map { $0.value as String }.joined(separator: " / ")
            return "• \(name) \(phones) \(emails)".trimmingCharacters(in: .whitespaces)
        }
        return .ok("找到 \(contacts.count) 个联系人", payload: .object([
            "count": .number(Double(contacts.count))
        ]), modelText: lines.isEmpty ? "没有匹配的联系人。" : lines.joined(separator: "\n"))
    }
}

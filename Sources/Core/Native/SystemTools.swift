import Foundation
import UIKit
import HealthKit
import Photos
import MapKit
import HomeKit
import UserNotifications

// MARK: - 健康

@MainActor
final class HealthTool: AgentTool {
    private let store = HKHealthStore()

    var definition: ToolDefinition {
        ToolDefinition(
            name: "health",
            summary: "读步数、心率、睡眠、体重；也可以写入体重和训练。action=read/write。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("read | write"),
                "metric": .stringParam("steps | heart_rate | sleep | weight | workout"),
                "days": .numberParam("读取最近几天，默认 1"),
                "value": .numberParam("写入时的数值"),
                "unit": .stringParam("写入单位，例如 kg / min")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard HKHealthStore.isHealthDataAvailable() else { throw ToolError.unavailable("这台设备没有健康数据") }

        let readTypes: Set<HKObjectType> = [
            HKQuantityType(.stepCount),
            HKQuantityType(.heartRate),
            HKQuantityType(.bodyMass),
            HKCategoryType(.sleepAnalysis)
        ]
        try await store.requestAuthorization(toShare: [HKQuantityType(.bodyMass)], read: readTypes)

        let action = arguments["action"]?.stringValue ?? "read"
        let days = arguments["days"]?.intValue ?? 1
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end

        if action == "read" {
            let metric = arguments["metric"]?.stringValue ?? "steps"
            switch metric {
            case "steps":
                let value = try await sum(.stepCount, unit: .count(), from: start, to: end)
                return .ok("最近 \(days) 天步数：\(Int(value))", modelText: "最近 \(days) 天共 \(Int(value)) 步。")
            case "heart_rate":
                let value = try await average(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end)
                return .ok("平均心率 \(Int(value)) 次/分", modelText: "最近 \(days) 天平均心率 \(Int(value)) 次/分。")
            case "weight":
                let samples = try await latest(.bodyMass, unit: .gramUnit(with: .kilo))
                return .ok("最新体重 \(samples)", modelText: "最新体重 \(samples) 公斤。")
            default:
                return .ok("已读取健康数据", modelText: "健康数据可用：步数、心率、睡眠、体重。")
            }
        }

        guard let value = arguments["value"]?.doubleValue else { throw ToolError.badInput("写入需要 value") }
        if arguments["metric"]?.stringValue == "weight" {
            let quantity = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: value)
            let sample = HKQuantitySample(type: HKQuantityType(.bodyMass), quantity: quantity, start: Date(), end: Date())
            try await store.save(sample)
            return .ok("已记录体重 \(value) kg")
        }
        throw ToolError.unavailable("这个指标暂不支持写入")
    }

    private func sum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async throws -> Double {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: HKQuantityType(identifier),
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit) ?? 0)
            }
            store.execute(query)
        }
    }

    private func average(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async throws -> Double {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: HKQuantityType(identifier),
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: statistics?.averageQuantity()?.doubleValue(for: unit) ?? 0)
            }
            store.execute(query)
        }
    }

    private func latest(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> String {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(identifier))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try await descriptor.result(for: store)
        guard let sample = samples.first else { return "没有记录" }
        return String(format: "%.1f", sample.quantity.doubleValue(for: unit))
    }
}

// MARK: - 照片

@MainActor
final class PhotoTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "photos",
            summary: "找最近的照片、按日期筛选，返回缩略图供你看；也可以用系统视觉识别画面内容。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("recent | search"),
                "days": .numberParam("最近几天，默认 7"),
                "limit": .numberParam("返回数量，默认 8")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw ToolError.permissionDenied("照片") }

        let days = arguments["days"]?.intValue ?? 7
        let limit = min(arguments["limit"]?.intValue ?? 8, 20)
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)

        let assets = PHAsset.fetchAssets(with: options)
        var descriptions: [String] = []
        var payloads: [JSONValue] = []

        assets.enumerateObjects { asset, _, _ in
            let date = asset.creationDate.map { DateParsing.string($0) } ?? "未知时间"
            descriptions.append("• \(date) \(asset.mediaType == .video ? "视频" : "照片") \(asset.pixelWidth)×\(asset.pixelHeight)")
            payloads.append(.object([
                "local_identifier": .string(asset.localIdentifier),
                "width": .number(Double(asset.pixelWidth)),
                "height": .number(Double(asset.pixelHeight)),
                "is_video": .bool(asset.mediaType == .video)
            ]))
        }

        return .ok("找到 \(assets.count) 张", payload: .object(["assets": .array(payloads)]),
                   modelText: descriptions.isEmpty ? "最近 \(days) 天没有照片。" : descriptions.joined(separator: "\n"))
    }
}

// MARK: - 地图

@MainActor
final class MapTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "maps",
            summary: "搜索地点、算路线、打开导航。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("search | directions"),
                "query": .stringParam("要找的地方，例如 最近的咖啡"),
                "destination": .stringParam("导航终点"),
                "mode": .stringParam("walking | driving | transit")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let action = arguments["action"]?.stringValue ?? "search"

        if action == "search" {
            guard let query = arguments["query"]?.stringValue else { throw ToolError.badInput("缺少 query") }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            let response = try await MKLocalSearch(request: request).start()
            let lines = response.mapItems.prefix(8).map { item -> String in
                "• \(item.name ?? "") \(item.placemark.title ?? "")"
            }
            return .ok("找到 \(response.mapItems.count) 个地点", modelText: lines.joined(separator: "\n"))
        }

        guard let destination = arguments["destination"]?.stringValue,
              let encoded = destination.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://maps.apple.com/?daddr=\(encoded)&dirflg=\(arguments["mode"]?.stringValue ?? "d")") else {
            throw ToolError.badInput("缺少 destination")
        }
        _ = await UIApplication.shared.open(url)
        return .ok("已打开到 \(destination) 的路线")
    }
}

// MARK: - 音乐

@MainActor
final class MusicTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "music",
            summary: "打开 Apple Music 播放指定歌单或歌曲。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "query": .stringParam("歌名、歌手或歌单")
            ], required: ["query"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let query = arguments["query"]?.stringValue,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "music://music.apple.com/search?term=\(encoded)") else {
            throw ToolError.badInput("缺少 query")
        }
        _ = await UIApplication.shared.open(url)
        return .ok("已在 Apple Music 搜索「\(query)」")
    }
}

// MARK: - 消息

@MainActor
final class MessageTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "compose_message",
            summary: "写好一条短信/iMessage 并打开信息 App，发送键留给你按。",
            surface: .native,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "to": .stringParam("收件人手机号或姓名"),
                "body": .stringParam("正文")
            ], required: ["to", "body"]),
            requiresForeground: true
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let to = arguments["to"]?.stringValue, let body = arguments["body"]?.stringValue else {
            throw ToolError.badInput("需要 to 和 body")
        }
        let request = ApprovalRequest(
            runID: context.runID, toolName: "compose_message",
            title: "确认发送消息", detail: "给 \(to)：\(body.prefix(80))",
            risk: .sensitive, kind: .message
        )
        switch await context.requestApproval(request) {
        case .allowed:
            break
        case .denied(let reason):
            return .denied(reason)
        case .expired:
            return .denied("确认超时")
        case .handoff:
            return .needsHuman("请本人发送", kind: "message")
        }

        guard let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedTo = to.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "sms:\(encodedTo)&body=\(encodedBody)") else {
            throw ToolError.badInput("号码无法编码")
        }
        _ = await UIApplication.shared.open(url)
        return .ok("已打开信息 App，正文已填好，等你按发送")
    }
}

// MARK: - 剪贴板

@MainActor
final class ClipboardTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "clipboard",
            summary: "读剪贴板，或把文字写进剪贴板。",
            surface: .native,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("read | write"),
                "text": .stringParam("要写入的文字")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        if arguments["action"]?.stringValue == "write" {
            UIPasteboard.general.string = arguments["text"]?.stringValue ?? ""
            return .ok("已写入剪贴板")
        }
        let text = UIPasteboard.general.string ?? ""
        return .ok("剪贴板有 \(text.count) 个字符", modelText: text.isEmpty ? "剪贴板是空的。" : String(text.prefix(2000)))
    }
}

// MARK: - 通知

@MainActor
final class NotificationTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "notify",
            summary: "发一条本地提醒通知，可以设延迟。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "title": .stringParam("标题"),
                "body": .stringParam("正文"),
                "in_seconds": .numberParam("多少秒后提醒，默认立即")
            ], required: ["title"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])

        let content = UNMutableNotificationContent()
        content.title = arguments["title"]?.stringValue ?? "pogent"
        content.body = arguments["body"]?.stringValue ?? ""
        content.sound = .default

        let delay = arguments["in_seconds"]?.doubleValue ?? 1
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 1), repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        try await center.add(request)
        return .ok("通知已排队")
    }
}

// MARK: - 快捷指令

@MainActor
final class ShortcutTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "run_shortcut",
            summary: "运行系统「快捷指令」里的一个快捷指令，用来扩展 pogent 没有的能力。",
            surface: .native,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "name": .stringParam("快捷指令名称"),
                "input": .stringParam("可选输入文本")
            ], required: ["name"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let name = arguments["name"]?.stringValue,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else {
            throw ToolError.badInput("缺少 name")
        }
        _ = await UIApplication.shared.open(url)
        return .ok("已运行快捷指令「\(name)」")
    }
}

// MARK: - 家庭

@MainActor
final class HomeTool: AgentTool {
    private let manager = HMHomeManager()

    var definition: ToolDefinition {
        ToolDefinition(
            name: "home",
            summary: "列出家庭配件并开关灯、插座、空调。action=list/set。",
            surface: .native,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("list | set"),
                "accessory": .stringParam("配件名称"),
                "on": .boolParam("开或关")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        // HMHomeManager 首次加载是异步的，这里等一小会儿。
        if manager.homes.isEmpty {
            try? await Task.sleep(for: .milliseconds(800))
        }
        let accessories = manager.homes.flatMap(\.accessories)

        if arguments["action"]?.stringValue == "list" {
            let lines = accessories.map { "• \($0.name)（\($0.category.localizedDescription)）" }
            return .ok("有 \(accessories.count) 个配件", modelText: lines.isEmpty ? "没有家庭配件。" : lines.joined(separator: "\n"))
        }

        guard let name = arguments["accessory"]?.stringValue,
              let accessory = accessories.first(where: { $0.name.contains(name) }) else {
            throw ToolError.badInput("找不到配件")
        }
        let on = arguments["on"]?.boolValue ?? true
        let target = accessory.services
            .flatMap(\.characteristics)
            .first { $0.characteristicType == HMCharacteristicTypePowerState }

        guard let target else { return .failed("\(accessory.name) 不支持开关") }
        try await target.writeValue(on)
        return .ok("已\(on ? "打开" : "关闭") \(accessory.name)")
    }
}

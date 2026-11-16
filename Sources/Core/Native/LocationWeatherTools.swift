import Foundation
import UserNotifications
import CoreLocation
import MapKit
import Observation
import UIKit

/// 闹钟与倒计时。
///
/// 上游 Poki 在 iOS 上做的是“到点弹通知”，Fish Pocket 只能建提醒事项。
/// iOS 26 起有 AlarmKit，但需要额外授权且未签名包用不了；
/// 这里用通知 + 前台计时器实现同等效果：锁屏能响，打开 App 能看倒计时。
@MainActor
@Observable
final class ClockService {
    struct Alarm: Codable, Identifiable, Sendable {
        var id: String
        var title: String
        var fireAt: Date
        var repeatsDaily: Bool
        var sound: Bool
    }

    private(set) var alarms: [Alarm] = []
    private(set) var activeTimer: (end: Date, label: String)?
    private var timerTask: Task<Void, Never>?
    private let fileURL: URL
    private let center = UNUserNotificationCenter.current()

    init(workspace: URL) {
        fileURL = workspace.appendingPathComponent("alarms.json")
        load()
    }

    // MARK: 闹钟

    func schedule(title: String, at date: Date, repeatsDaily: Bool = false, sound: Bool = true) async throws {
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else { throw ToolError.permissionDenied("通知") }

        let alarm = Alarm(id: UUID().uuidString, title: title, fireAt: date, repeatsDaily: repeatsDaily, sound: sound)
        alarms.append(alarm)
        persist()

        let content = UNMutableNotificationContent()
        content.title = "pogent 闹钟"
        content.body = title
        content.sound = sound ? .default : nil
        content.interruptionLevel = .timeSensitive

        var components = Calendar.current.dateComponents([.hour, .minute], from: date)
        components.second = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeatsDaily)
        let request = UNNotificationRequest(identifier: "alarm-\(alarm.id)", content: content, trigger: trigger)
        try await center.add(request)
    }

    func cancel(id: String) {
        alarms.removeAll { $0.id == id }
        center.removePendingNotificationRequests(withIdentifiers: ["alarm-\(id)"])
        persist()
    }

    // MARK: 倒计时

    func startTimer(minutes: Double, label: String) async throws {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw ToolError.permissionDenied("通知") }

        let end = Date().addingTimeInterval(minutes * 60)
        activeTimer = (end, label)

        let content = UNMutableNotificationContent()
        content.title = "倒计时结束"
        content.body = label
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(minutes * 60, 1), repeats: false)
        try await center.add(UNNotificationRequest(
            identifier: "timer-\(label)", content: content, trigger: trigger
        ))

        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let active = self.activeTimer, active.end <= Date() {
                    self.activeTimer = nil
                    Presentation.success()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopTimer() {
        timerTask?.cancel()
        activeTimer = nil
        center.removePendingNotificationRequests(withIdentifiers: ["timer"])
    }

    var remaining: TimeInterval {
        guard let active = activeTimer else { return 0 }
        return max(active.end.timeIntervalSinceNow, 0)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(alarms) { try? data.write(to: fileURL) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Alarm].self, from: data) else { return }
        alarms = decoded.filter { $0.repeatsDaily || $0.fireAt > Date() }
    }
}

// MARK: - 工具

@MainActor
final class ClockTool: AgentTool {
    private let clock: ClockService

    init(clock: ClockService) { self.clock = clock }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "clock",
            summary: "定闹钟、开倒计时、查世界时间、算时间差。action=alarm/timer/world/diff。",
            surface: .native,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("alarm | timer | world | diff | list | cancel"),
                "title": .stringParam("闹钟或倒计时的名字"),
                "time": .stringParam("闹钟时间，HH:mm 或 ISO8601"),
                "minutes": .numberParam("倒计时分钟数"),
                "repeat": .boolParam("是否每天重复"),
                "zone": .stringParam("时区，例如 Asia/Tokyo"),
                "id": .stringParam("取消闹钟时的 id")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let action = arguments["action"]?.stringValue ?? ""

        switch action {
        case "alarm":
            guard let raw = arguments["time"]?.stringValue else { throw ToolError.badInput("缺少 time") }
            guard let date = Self.parseClock(raw) else { throw ToolError.badInput("时间格式看不懂：\(raw)") }
            let title = arguments["title"]?.stringValue ?? "起床"
            try await clock.schedule(
                title: title,
                at: date,
                repeatsDaily: arguments["repeat"]?.boolValue ?? false,
                sound: true
            )
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日 HH:mm"
            return .ok("闹钟已设：\(formatter.string(from: date)) \(title)")

        case "timer":
            let minutes = arguments["minutes"]?.doubleValue ?? 25
            let label = arguments["title"]?.stringValue ?? "倒计时"
            try await clock.startTimer(minutes: minutes, label: label)
            return .ok("倒计时 \(Int(minutes)) 分钟已开始：\(label)")

        case "world":
            let zoneID = arguments["zone"]?.stringValue ?? "Asia/Tokyo"
            guard let zone = TimeZone(identifier: zoneID) else {
                throw ToolError.badInput("不认识的时区：\(zoneID)")
            }
            let formatter = DateFormatter()
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd HH:mm EEEE"
            formatter.locale = Locale(identifier: "zh_CN")
            let offset = zone.secondsFromGMT() / 3600
            return .ok("\(zoneID)：\(formatter.string(from: Date()))（UTC\(offset >= 0 ? "+" : "")\(offset)）")

        case "diff":
            guard let a = arguments["time"]?.stringValue else { throw ToolError.badInput("缺少 time") }
            let parts = a.split(separator: "|").map(String.init)
            guard parts.count == 2,
                  let d1 = DateParsing.date(parts[0]), let d2 = DateParsing.date(parts[1]) else {
                throw ToolError.badInput("用 | 分隔两个时间，例如 2026-01-01|2026-02-01")
            }
            let interval = abs(d2.timeIntervalSince(d1))
            let days = Int(interval / 86400)
            let hours = Int(interval.truncatingRemainder(dividingBy: 86400) / 3600)
            return .ok("相差 \(days) 天 \(hours) 小时")

        case "list":
            guard !clock.alarms.isEmpty else { return .ok("没有待触发的闹钟") }
            let formatter = DateFormatter()
            formatter.dateFormat = "M-d HH:mm"
            let lines = clock.alarms.map { "• \(formatter.string(from: $0.fireAt)) \($0.title)\($0.repeatsDaily ? "（每天）" : "")" }
            return .ok(lines.joined(separator: "\n"))

        case "cancel":
            guard let id = arguments["id"]?.stringValue else { throw ToolError.badInput("缺少 id") }
            clock.cancel(id: id)
            return .ok("已取消")

        default:
            throw ToolError.badInput("未知动作：\(action)")
        }
    }

    static func parseClock(_ raw: String) -> Date? {
        if let iso = DateParsing.date(raw) { return iso }
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = parts[0]
        components.minute = parts[1]
        guard var date = Calendar.current.date(from: components) else { return nil }
        if date < Date() { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }
}

// MARK: - 位置

@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuations: [CheckedContinuation<CLLocation?, Never>] = []

    private(set) var lastLocation: CLLocation?
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async -> CLLocation? {
        if let lastLocation, lastLocation.timestamp.timeIntervalSinceNow > -60 { return lastLocation }

        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.requestLocation()

        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self.flush(nil)
            }
        }
    }

    private func flush(_ location: CLLocation?) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume(returning: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in
            self.lastLocation = location
            self.flush(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.flush(self.lastLocation) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.requestLocation()
            } else if status == .denied || status == .restricted {
                self.flush(nil)
            }
        }
    }
}

@MainActor
final class LocationTool: AgentTool {
    private let service: LocationService

    init(service: LocationService) { self.service = service }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "location",
            summary: "当前位置（经纬度 + 地址）、两点距离、附近地点。action=current/distance/nearby。",
            surface: .native,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("current | distance | nearby"),
                "query": .stringParam("nearby 时找什么，例如 咖啡"),
                "to": .stringParam("distance 时的目的地，写地址或 lat,lng")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let action = arguments["action"]?.stringValue ?? "current"
        guard let location = await service.current() else {
            throw ToolError.permissionDenied("位置")
        }

        switch action {
        case "current":
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            let address = [placemark?.name, placemark?.locality, placemark?.subLocality]
                .compactMap { $0 }.joined(separator: " ")
            return .ok(String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)
                        + (address.isEmpty ? "" : "\n\(address)"),
                       payload: .object([
                        "lat": .number(location.coordinate.latitude),
                        "lng": .number(location.coordinate.longitude),
                        "address": .string(address)
                       ]))

        case "distance":
            guard let raw = arguments["to"]?.stringValue else { throw ToolError.badInput("缺少 to") }
            let destination: CLLocation
            if let coordinate = Self.coordinate(raw) {
                destination = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            } else if let placemark = try? await CLGeocoder().geocodeAddressString(raw).first,
                      let coordinate = placemark.location {
                destination = coordinate
            } else {
                throw ToolError.badInput("找不到这个地点：\(raw)")
            }
            let meters = location.distance(from: destination)
            return .ok(String(format: "直线距离 %.1f 公里", meters / 1000))

        case "nearby":
            let query = arguments["query"]?.stringValue ?? "咖啡"
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 3000,
                longitudinalMeters: 3000
            )
            let response = try await MKLocalSearch(request: request).start()
            let lines = response.mapItems.prefix(6).map { item -> String in
                let distance = item.placemark.location.map { location.distance(from: $0) } ?? 0
                return "• \(item.name ?? "")  \(Int(distance)) 米"
            }
            return .ok(lines.isEmpty ? "附近没找到" : lines.joined(separator: "\n"))

        default:
            throw ToolError.badInput("未知动作：\(action)")
        }
    }

    static func coordinate(_ raw: String) -> CLLocationCoordinate2D? {
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }
}

// MARK: - 天气

@MainActor
final class WeatherTool: AgentTool {
    private let location: LocationService

    init(location: LocationService) { self.location = location }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "weather",
            summary: "查当前天气和未来几天预报。不用 API Key，数据来自 open-meteo。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "city": .stringParam("城市名，留空则用当前位置"),
                "days": .numberParam("预报天数 1–7，默认 3")
            ])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let days = min(max(Int(arguments["days"]?.doubleValue ?? 3), 1), 7)
        var latitude: Double
        var longitude: Double

        if let city = arguments["city"]?.stringValue, !city.isEmpty {
            let placemarks = try await CLGeocoder().geocodeAddressString(city)
            guard let coordinate = placemarks.first?.location?.coordinate else {
                throw ToolError.badInput("找不到城市：\(city)")
            }
            latitude = coordinate.latitude
            longitude = coordinate.longitude
        } else {
            guard let current = await location.current() else {
                throw ToolError.permissionDenied("位置")
            }
            latitude = current.coordinate.latitude
            longitude = current.coordinate.longitude
        }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "forecast_days", value: String(days)),
            .init(name: "timezone", value: "auto")
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToolError.unavailable("天气服务暂时不可用")
        }
        return .ok(Self.format(data), payload: .object(["raw": .string(String(data: data, encoding: .utf8) ?? "")]))
    }

    static func format(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "天气数据解析失败"
        }
        var lines: [String] = []
        if let current = root["current"] as? [String: Any] {
            let temperature = current["temperature_2m"] as? Double ?? 0
            let feels = current["apparent_temperature"] as? Double ?? 0
            let humidity = current["relative_humidity_2m"] as? Double ?? 0
            let wind = current["wind_speed_10m"] as? Double ?? 0
            let code = current["weather_code"] as? Int ?? 0
            lines.append("现在 \(Int(temperature))°C，体感 \(Int(feels))°C，\(describe(code))")
            lines.append("湿度 \(Int(humidity))%，风速 \(Int(wind)) km/h")
        }
        if let daily = root["daily"] as? [String: Any],
           let dates = daily["time"] as? [String],
           let codes = daily["weather_code"] as? [Int],
           let highs = daily["temperature_2m_max"] as? [Double],
           let lows = daily["temperature_2m_min"] as? [Double],
           let rain = daily["precipitation_probability_max"] as? [Int] {
            lines.append("")
            for index in dates.indices where index < codes.count && index < highs.count {
                lines.append("\(dates[index])  \(describe(codes[index]))  \(Int(lows[index]))–\(Int(highs[index]))°C  降水 \(index < rain.count ? rain[index] : 0)%")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "晴"
        case 1, 2: "晴间多云"
        case 3: "阴"
        case 45, 48: "雾"
        case 51, 53, 55: "毛毛雨"
        case 56, 57: "冻雨"
        case 61, 63, 65: "雨"
        case 66, 67: "冻雨"
        case 71, 73, 75: "雪"
        case 77: "雪粒"
        case 80, 81, 82: "阵雨"
        case 85, 86: "阵雪"
        case 95: "雷雨"
        case 96, 99: "雷雨伴冰雹"
        default: "多云"
        }
    }
}

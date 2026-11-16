import Foundation
import UIKit
import AVFoundation
import CoreMotion
import Network
import Observation

/// UIKit 与 SwiftUI 之间的桥：找最上层控制器、弹系统面板、轻反馈。
@MainActor
enum Presentation {
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        if let navigation = controller as? UINavigationController {
            return navigation.visibleViewController ?? navigation
        }
        if let tab = controller as? UITabBarController {
            return tab.selectedViewController ?? tab
        }
        return controller
    }

    static func present(_ controller: UIViewController, animated: Bool = true) async -> Bool {
        guard let top = topViewController() else { return false }
        return await withCheckedContinuation { continuation in
            top.present(controller, animated: animated) {
                continuation.resume(returning: true)
            }
        }
    }

    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func failure() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    static func isForeground() -> Bool {
        UIApplication.shared.applicationState == .active
    }
}

// MARK: - 设备信息

@MainActor
final class DeviceInfoTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "device_info",
            summary: "读设备型号、系统版本、屏幕、存储、内存、电池、网络、语言、时区。",
            surface: .native,
            risk: .safe
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let screen = UIScreen.main

        let storage = Self.storage()
        let memory = ProcessInfo.processInfo.physicalMemory
        let battery = device.batteryLevel < 0 ? "未知" : "\(Int(device.batteryLevel * 100))%"
        let charging: String = switch device.batteryState {
        case .charging: "充电中"
        case .full: "已充满"
        case .unplugged: "使用电池"
        default: "未知"
        }

        let text = """
        型号：\(device.model)（\(Self.machineIdentifier())）
        系统：\(device.systemName) \(device.systemVersion)
        屏幕：\(Int(screen.bounds.width))×\(Int(screen.bounds.height)) @\(Int(screen.scale))x，亮度 \(Int(screen.brightness * 100))%
        存储：已用 \(Self.gb(storage.used)) / 共 \(Self.gb(storage.total))
        内存：\(Self.gb(Int64(memory)))
        电池：\(battery)，\(charging)
        网络：\(NetworkMonitor.shared.summary)
        语言：\(Locale.preferredLanguages.prefix(2).joined(separator: ", "))
        时区：\(TimeZone.current.identifier)
        """

        return .ok(text, payload: .object([
            "system": .string(device.systemVersion),
            "model": .string(device.model),
            "battery": .number(Double(max(device.batteryLevel, 0)))
        ]))
    }

    static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce(into: "") { result, element in
            if let value = element.value as? Int8, value != 0 {
                result.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
    }

    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    static func storage() -> (used: Int64, total: Int64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return (max(total - free, 0), total)
    }
}

/// 网络状态。用 NWPathMonitor 持续观察。
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true
    private(set) var isExpensive = false
    private(set) var isWiFi = false
    private var monitor: NWPathMonitor?

    private init() { start() }

    private func start() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = path.status == .satisfied
                self.isExpensive = path.isExpensive
                self.isWiFi = path.usesInterfaceType(.wifi)
            }
        }
        monitor.start(queue: DispatchQueue(label: "bot.pogent.network"))
        self.monitor = monitor
    }

    var summary: String {
        if !isOnline { return "离线" }
        return isWiFi ? "Wi-Fi" : (isExpensive ? "蜂窝（省流量）" : "蜂窝")
    }
}

@MainActor
final class BatteryTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "battery",
            summary: "读电量、充电状态、低电量模式，可开关低电量模式。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("read | low_power_on | low_power_off")
            ])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let action = arguments["action"]?.stringValue ?? "read"

        if action == "low_power_on" || action == "low_power_off" {
            // 低电量模式没有公开 API，只能深链到设置页。
            if let url = URL(string: "App-Prefs:BATTERY_USAGE") {
                _ = await UIApplication.shared.open(url)
            }
            return .ok("已打开电池设置，低电量模式需要你手动切换（系统不开放这个接口）")
        }

        let level = device.batteryLevel < 0 ? 0 : Int(device.batteryLevel * 100)
        let state: String = switch device.batteryState {
        case .charging: "充电中"
        case .full: "已充满"
        case .unplugged: "使用电池"
        default: "未知"
        }
        return .ok("电量 \(level)%，\(state)，低电量模式：\(ProcessInfo.processInfo.isLowPowerModeEnabled ? "开" : "关")",
                   payload: .object(["level": .number(Double(level)), "charging": .bool(device.batteryState != .unplugged)]))
    }
}

// MARK: - 硬件控制

@MainActor
final class HardwareTool: AgentTool {
    private let motion = CMMotionManager()

    var definition: ToolDefinition {
        ToolDefinition(
            name: "hardware",
            summary: "手电筒、屏幕亮度、触感、姿态传感器（加速度/陀螺仪）。action=flashlight/brightness/motion/haptic。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("flashlight | brightness | motion | haptic"),
                "on": .boolParam("手电筒开关"),
                "value": .numberParam("亮度 0–1")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let action = arguments["action"]?.stringValue ?? ""

        switch action {
        case "flashlight":
            guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
                throw ToolError.unavailable("这台设备没有闪光灯")
            }
            let on = arguments["on"]?.boolValue ?? true
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
            return .ok("手电筒已\(on ? "打开" : "关闭")")

        case "brightness":
            let value = min(max(arguments["value"]?.doubleValue ?? 0.5, 0), 1)
            UIScreen.main.brightness = CGFloat(value)
            return .ok("屏幕亮度调到 \(Int(value * 100))%")

        case "motion":
            guard motion.isAccelerometerAvailable else { throw ToolError.unavailable("没有加速度计") }
            motion.accelerometerUpdateInterval = 0.2
            motion.startAccelerometerUpdates()
            try? await Task.sleep(nanoseconds: 400_000_000)
            let acceleration = motion.accelerometerData?.acceleration
            motion.stopAccelerometerUpdates()
            guard let acceleration else { throw ToolError.unavailable("读不到传感器") }
            return .ok(String(format: "加速度 x=%.2f y=%.2f z=%.2f", acceleration.x, acceleration.y, acceleration.z))

        case "haptic":
            Presentation.haptic(.heavy)
            return .ok("已触发触感反馈")

        default:
            throw ToolError.badInput("未知动作：\(action)")
        }
    }
}

@MainActor
final class AuthenticateTool: AgentTool {
    private let capabilities: CapabilityCenter

    init(capabilities: CapabilityCenter) { self.capabilities = capabilities }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "authenticate",
            summary: "用 Face ID / 触控 ID 确认是你本人。高风险操作前调用。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "reason": .stringParam("为什么要验证，会显示在系统弹窗上")
            ])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let reason = arguments["reason"]?.stringValue ?? "确认是你本人"
        let ok = await capabilities.authenticate(reason: reason)
        return ok ? .ok("已验证") : .failed("验证没有通过")
    }
}

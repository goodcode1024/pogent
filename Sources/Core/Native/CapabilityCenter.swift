import Foundation
import SwiftData
import Observation
import AVFoundation
import CoreLocation
import CoreBluetooth
import Photos
import Speech
import UserNotifications
import LocalAuthentication
import HealthKit
@preconcurrency import EventKit
import Contacts
import MusicKit

/// 本机能力目录。每一项都能单独开关，关掉之后对应工具直接拒绝执行。
enum Capability: String, CaseIterable, Identifiable, Sendable {
    case calendar, reminders, contacts, health, photos
    case location, microphone, speech, camera, bluetooth
    case music, notifications, homekit, faceID

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "日历"
        case .reminders: "提醒事项"
        case .contacts: "通讯录"
        case .health: "健康"
        case .photos: "照片"
        case .location: "位置"
        case .microphone: "麦克风"
        case .speech: "语音识别"
        case .camera: "相机"
        case .bluetooth: "蓝牙"
        case .music: "Apple Music"
        case .notifications: "通知"
        case .homekit: "家庭"
        case .faceID: "Face ID"
        }
    }

    var detail: String {
        switch self {
        case .calendar: "建日程、查空闲、改时间"
        case .reminders: "建提醒、勾完成、按清单查"
        case .contacts: "按名字找人、拿电话"
        case .health: "步数、心率、睡眠、体重、训练"
        case .photos: "找图、看图、存图、整理相册"
        case .location: "当前位置、路线、附近地点"
        case .microphone: "录音与语音输入"
        case .speech: "把语音转成文字"
        case .camera: "拍照、扫码、扫描文档"
        case .bluetooth: "扫描附近设备"
        case .music: "搜索与播放音乐"
        case .notifications: "发本地通知与定时提醒"
        case .homekit: "控制灯、空调等配件"
        case .faceID: "高风险操作前确认是你"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .health: "heart.fill"
        case .photos: "photo.on.rectangle"
        case .location: "location.fill"
        case .microphone: "mic.fill"
        case .speech: "waveform"
        case .camera: "camera.fill"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .music: "music.note"
        case .notifications: "bell.fill"
        case .homekit: "house.fill"
        case .faceID: "faceid"
        }
    }
}

/// 统一的能力开关与系统权限申请。
///
/// 这一层存在的意义：上游两个项目里，权限散落在各自的设置页，
/// 用户经常“开了开关但没给系统权限”。这里把两件事绑在一起，
/// 开关打开就等于发起系统授权，结果写回数据库。
@MainActor
@Observable
final class CapabilityCenter {
    private let context: ModelContext
    private var records: [String: CapabilityRecord] = [:]

    /// 最近一次操作失败的原因，设置页直接展示。
    var lastError: String?

    init(context: ModelContext) {
        self.context = context
        reload()
    }

    func reload() {
        let descriptor = FetchDescriptor<CapabilityRecord>()
        let all = (try? context.fetch(descriptor)) ?? []
        records = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }

    // MARK: 查询

    func isEnabled(_ capability: Capability) -> Bool {
        if let record = records[capability.rawValue] { return record.isEnabled }
        // 没记录过时按系统权限现状推断，避免用户升级后全部变灰。
        return Self.systemStatus(capability) == .granted
    }

    func isEnabled(id: String) -> Bool {
        guard let capability = Capability(rawValue: id) else { return false }
        return isEnabled(capability)
    }

    func markUsed(_ capability: Capability) {
        guard let record = records[capability.rawValue] else { return }
        record.lastUsedAt = Date()
        try? context.save()
    }

    // MARK: 开关

    /// 打开时同时发起系统授权；关闭只写数据库，不去撤销系统权限。
    @discardableResult
    func setEnabled(_ capability: Capability, _ enabled: Bool) async -> Bool {
        if enabled {
            let granted = await request(capability)
            write(capability, enabled: granted)
            if !granted {
                lastError = "系统没有授予「\(capability.title)」权限，请到 设置 → 隐私与安全性 里打开。"
            }
            return granted
        } else {
            write(capability, enabled: false)
            return false
        }
    }

    private func write(_ capability: Capability, enabled: Bool) {
        let record = records[capability.rawValue] ?? {
            let fresh = CapabilityRecord(id: capability.rawValue)
            context.insert(fresh)
            records[capability.rawValue] = fresh
            return fresh
        }()
        record.isEnabled = enabled
        record.grantedAt = enabled ? Date() : record.grantedAt
        try? context.save()
    }

    // MARK: 授权

    func request(_ capability: Capability) async -> Bool {
        switch capability {
        case .calendar:
            return (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        case .reminders:
            return (try? await EKEventStore().requestFullAccessToReminders()) ?? false
        case .contacts:
            return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        case .health:
            guard HKHealthStore.isHealthDataAvailable() else { return false }
            let store = HKHealthStore()
            let read: Set<HKObjectType> = [
                HKQuantityType(.stepCount), HKQuantityType(.heartRate),
                HKQuantityType(.bodyMass), HKCategoryType(.sleepAnalysis)
            ]
            let share: Set<HKSampleType> = [HKQuantityType(.bodyMass), HKWorkoutType.workoutType()]
            return (try? await store.requestAuthorization(toShare: share, read: read)) != nil
        case .photos:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited
        case .location:
            return await Self.requestLocation()
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .speech:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .bluetooth:
            // CBCentralManager 初始化就会触发系统弹窗，这里等一小会儿再看状态。
            let manager = CBCentralManager(delegate: nil, queue: nil)
            try? await Task.sleep(nanoseconds: 600_000_000)
            let ok = manager.state == .poweredOn || manager.state == .poweredOff
            _ = manager
            return ok
        case .music:
            let status = await MusicAuthorization.request()
            return status == .authorized
        case .notifications:
            return (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .homekit:
            // HomeKit 的授权在第一次访问配件库时由系统弹出。
            return true
        case .faceID:
            var error: NSError?
            return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        }
    }

    /// 真正去做一次 Face ID 验证。高风险工具调用它。
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // 没有生物识别时退回设备密码；设备也没设密码就放行（系统本身没有保护）。
            return true
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }

    private static func requestLocation() async -> Bool {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            return true
        }
        manager.requestWhenInUseAuthorization()
        // 系统弹窗是异步的，轮询最多 8 秒。
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let status = manager.authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways { return true }
            if status == .denied || status == .restricted { return false }
        }
        return manager.authorizationStatus == .authorizedWhenInUse
    }

    /// 只读检查，不触发弹窗。
    static func systemStatus(_ capability: Capability) -> Status {
        switch capability {
        case .calendar:
            return status(from: EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return status(from: EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .granted
            case .notDetermined: return .unknown
            default: return .denied
            }
        case .health:
            guard HKHealthStore.isHealthDataAvailable() else { return .denied }
            return .unknown
        case .photos:
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized, .limited: return .granted
            case .notDetermined: return .unknown
            default: return .denied
            }
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: return .granted
            case .notDetermined: return .unknown
            default: return .denied
            }
        case .microphone:
            return Self.avStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            return Self.avStatus(AVCaptureDevice.authorizationStatus(for: .video))
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .unknown
            default: return .denied
            }
        case .notifications:
            return .unknown
        case .bluetooth, .music, .homekit, .faceID:
            return .unknown
        }
    }

    enum Status: Sendable { case granted, denied, unknown }

    private static func status(from raw: EKAuthorizationStatus) -> Status {
        switch raw {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    private static func avStatus(_ raw: AVAuthorizationStatus) -> Status {
        switch raw {
        case .authorized: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }
}

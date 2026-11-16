import Foundation
import Observation
import AVFoundation
@preconcurrency import Speech

/// 实时语音输入。按住说话，松手把整段文字交给对话。
@MainActor
@Observable
final class SpeechService {
    private(set) var isRecording = false
    private(set) var transcript = ""
    private(set) var level: Double = 0
    var errorText: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func start() async {
        guard !isRecording else { return }
        errorText = nil
        transcript = ""

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            errorText = "语音识别没有授权。到 设置 → pogent → 语音识别 打开。"
            return
        }

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            errorText = "麦克风没有授权。到 设置 → pogent → 麦克风 打开。"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer?.supportsOnDeviceRecognition == true {
                request.requiresOnDeviceRecognition = true
            }

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            engine.prepare()
            try engine.start()

            audioEngine = engine
            self.request = request
            isRecording = true

            task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal { self.finish() }
                    }
                    if let error, self.transcript.isEmpty {
                        self.errorText = "识别失败：\(error.localizedDescription)"
                        self.finish()
                    }
                }
            }
        } catch {
            errorText = "麦克风打不开：\(error.localizedDescription)"
            finish()
        }
    }

    /// 停止并返回最终文本。
    @discardableResult
    func stop() -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        finish()
        return text
    }

    func cancel() {
        transcript = ""
        finish()
    }

    private func finish() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// 朗读。用系统语音，不需要任何 API。
@MainActor
@Observable
final class SpeechSynthesizer {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    var voiceIdentifier: String?
    var rate: Float = 0.5

    /// 中文语音，优先选增强/高级音质。
    static var preferredChineseVoice: AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? voices.first
    }

    static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("en") }
            .sorted { $0.language < $1.language }
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? Self.preferredChineseVoice
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

// MARK: - 工具

@MainActor
final class SpeakTool: AgentTool {
    private let synthesizer: SpeechSynthesizer

    init(synthesizer: SpeechSynthesizer) { self.synthesizer = synthesizer }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "speak",
            summary: "把一段文字朗读出来。适合播报结果、念文章、做语音提醒。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "text": .stringParam("要朗读的文字"),
                "rate": .numberParam("语速 0.3–0.7，默认 0.5")
            ], required: ["text"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            throw ToolError.badInput("缺少 text")
        }
        if let rate = arguments["rate"]?.numberValue {
            synthesizer.rate = Float(min(max(rate, 0.3), 0.7))
        }
        synthesizer.speak(text)
        return .ok("正在朗读 \(text.count) 个字", payload: .object(["chars": .number(Double(text.count))]))
    }
}

/// 对工作区里的音频文件做离线转写（不占用麦克风，也不需要联网）。
@MainActor
final class TranscribeTool: AgentTool {
    private let workspace: URL

    init(workspace: URL) { self.workspace = workspace }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "transcribe",
            summary: "把工作区里的音频或视频文件转成文字。支持 m4a、wav、mp3、mp4。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "path": .stringParam("相对工作区的路径，例如 recordings/会议.m4a"),
                "language": .stringParam("语言，默认 zh-CN")
            ], required: ["path"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let path = arguments["path"]?.stringValue else { throw ToolError.badInput("缺少 path") }
        let url = workspace.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.badInput("文件不存在：\(path)")
        }
        let language = arguments["language"]?.stringValue ?? "zh-CN"
        let text = try await Self.transcribe(url: url, language: language)
        return .ok(text.isEmpty ? "没有识别到语音" : text, payload: .object(["text": .string(text)]))
    }

    static func transcribe(url: URL, language: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            throw ToolError.unavailable("系统没有 \(language) 的语音识别器")
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw ToolError.permissionDenied("语音识别")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

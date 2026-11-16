import SwiftUI
import SwiftData

/// 语音对话：按住说话，松开就把这句话交给 pogent，回答会念出来。
struct VoiceConversationView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var conversation: Conversation?
    @State private var pressing = false
    @State private var lastReply = ""
    @State private var speakReplies = true

    var body: some View {
        ZStack {
            PogentTheme.background

            VStack(spacing: 22) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.07), in: Circle())
                    }
                    Spacer()
                    Text("语音")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        speakReplies.toggle()
                    } label: {
                        Image(systemName: speakReplies ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(speakReplies ? PogentTheme.accent : .secondary)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.07), in: Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer(minLength: 0)

                transcriptArea
                waveform

                Spacer(minLength: 0)

                holdButton

                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 24)
            }
        }
        .task {
            conversation = app.bootstrapConversation()
        }
        .onChange(of: app.runtime.isRunning) { _, running in
            guard !running, speakReplies, !lastReply.isEmpty else { return }
            app.synthesizer.speak(lastReply)
        }
    }

    private var transcriptArea: some View {
        VStack(spacing: 10) {
            if app.speech.isRecording, !app.speech.transcript.isEmpty {
                Text(app.speech.transcript)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else if app.runtime.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(app.runtime.streamingText.isEmpty ? "在想…" : app.runtime.streamingText)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(.horizontal, 24)
            } else if !lastReply.isEmpty {
                Text(lastReply)
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .lineLimit(6)
                    .padding(.horizontal, 24)
            } else {
                VStack(spacing: 8) {
                    Text("按住下面说话")
                        .font(.system(size: 17, weight: .semibold))
                    Text("不用打开对话页。松手就执行，结果会念给你听。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 30)
            }

            if let error = app.speech.errorText {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(PogentTheme.rose)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(minHeight: 120)
    }

    private var waveform: some View {
        HStack(spacing: 4) {
            ForEach(0..<32, id: \.self) { index in
                Capsule()
                    .fill(PogentTheme.accent.opacity(app.speech.isRecording ? 0.85 : 0.18))
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .frame(height: 54)
        .animation(.easeOut(duration: 0.18), value: app.speech.isRecording)
        .animation(.easeOut(duration: 0.25), value: app.speech.transcript)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard app.speech.isRecording else { return 8 }
        let seed = Double(app.speech.transcript.count + index)
        return 8 + CGFloat(abs(sin(seed * 0.55)) * 38 + abs(cos(seed * 0.21)) * 8)
    }

    private var holdButton: some View {
        ZStack {
            Circle()
                .fill(app.speech.isRecording ? PogentTheme.rose.opacity(0.22) : PogentTheme.accent.opacity(0.14))
                .frame(width: 128, height: 128)
            Circle()
                .stroke(app.speech.isRecording ? PogentTheme.rose.opacity(0.6) : PogentTheme.accent.opacity(0.4), lineWidth: 1.2)
                .frame(width: 128, height: 128)
            Image(systemName: app.speech.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(app.speech.isRecording ? PogentTheme.rose : PogentTheme.accent)
        }
        .scaleEffect(pressing ? 0.94 : 1)
        .animation(.spring(response: 0.25), value: pressing)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing, !app.runtime.isRunning else { return }
                    pressing = true
                    Presentation.haptic(.rigid)
                    Task { await app.speech.start() }
                }
                .onEnded { _ in
                    guard pressing else { return }
                    pressing = false
                    let text = app.speech.stop()
                    guard !text.isEmpty else { return }
                    send(text)
                }
        )
        .accessibilityLabel("按住说话")
    }

    private var hint: String {
        if app.runtime.isRunning { return "正在执行，点上面的 × 可以退出，任务会继续。" }
        if app.speech.isRecording { return "松手发送" }
        return "需要麦克风和语音识别权限。到「能力」里可以单独关闭。"
    }

    private func send(_ text: String) {
        guard let conversation else { return }
        lastReply = ""
        Task {
            await app.runtime.submit(text, conversation: conversation, context: context)
            lastReply = latestAssistantText()
        }
    }

    private func latestAssistantText() -> String {
        guard let conversation else { return "" }
        let history = ChatMessage.history(for: conversation.id, in: context, limit: 8)
        return history.last { $0.role == .assistant }?.text ?? ""
    }
}

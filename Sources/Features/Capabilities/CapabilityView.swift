import SwiftUI
import FoundationModels

/// 能力中心：所有本机能力的开关、快捷入口、完整工具清单。
struct CapabilityView: View {
    @Environment(AppEnvironment.self) private var app

    @State private var showVoice = false
    @State private var showScanner = false
    @State private var search = ""
    @State private var busy: Capability?
    @State private var toast: String?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modelCard
                    capabilityGrid
                    quickActions
                    toolList
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PogentTheme.background)
            .navigationTitle("能力")
            .navigationBarTitleDisplayMode(.large)
            .overlay(alignment: .top) {
                if let toast {
                    ToastView(text: toast)
                        .padding(.top, 8)
                        .onTapGesture { self.toast = nil }
                        .task {
                            try? await Task.sleep(nanoseconds: 2_200_000_000)
                            withAnimation { self.toast = nil }
                        }
                }
            }
            .sheet(isPresented: $showVoice) {
                VoiceConversationView()
            }
            .sheet(isPresented: $showScanner) {
                ScannerView()
            }
        }
    }

    // MARK: 模型状态

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(modelTitle)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(modelDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: modelIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(modelColor)
            }

            HStack(spacing: 6) {
                StatusPill(text: "\(app.registry.count) 个工具", color: PogentTheme.accent, icon: "square.grid.2x2")
                StatusPill(text: "\(app.memory.items.count) 条记忆", color: PogentTheme.violet, icon: "brain")
                StatusPill(text: "\(app.connectors.connectors.count) 个连接", color: PogentTheme.amber, icon: "link")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }

    private var modelTitle: String {
        if app.modelConfig.kind == .openAICompatible {
            let key = KeychainStore.apiKey(for: app.modelConfig.kind.rawValue) ?? ""
            return key.isEmpty ? "离线引擎" : "远端模型"
        }
        return SystemLanguageModel.default.availability == .available ? "端侧模型" : "离线引擎"
    }

    private var modelDetail: String {
        if app.modelConfig.kind == .openAICompatible {
            let key = KeychainStore.apiKey(for: app.modelConfig.kind.rawValue) ?? ""
            return key.isEmpty
                ? "还没填 API Key。现在用本机规则引擎，闹钟、天气、日程、算数、看图这些照样能办。"
                : "\(app.modelConfig.model) · \(app.modelConfig.baseURL)"
        }
        if SystemLanguageModel.default.availability == .available {
            return "Apple 端侧模型。不联网，复杂任务可到设置里换成远端模型。"
        }
        return "这台设备不支持 Apple 智能，已自动切到本机规则引擎。填一个 API Key 就能解锁完整对话。"
    }

    private var modelColor: Color {
        if app.modelConfig.kind == .openAICompatible {
            return (KeychainStore.apiKey(for: app.modelConfig.kind.rawValue) ?? "").isEmpty ? PogentTheme.amber : PogentTheme.accent
        }
        return SystemLanguageModel.default.availability == .available ? PogentTheme.violet : PogentTheme.amber
    }

    private var modelIcon: String {
        modelColor == PogentTheme.violet ? "cpu" : (modelColor == PogentTheme.accent ? "cloud.fill" : "bolt.slash.fill")
    }

    // MARK: 能力开关

    private var capabilityGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本机能力")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Capability.allCases) { capability in
                    capabilityCell(capability)
                }
            }

            Text("打开开关时会同时申请系统权限。关掉之后，任何工具都调用不了这一项。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func capabilityCell(_ capability: Capability) -> some View {
        let enabled = app.capabilities.isEnabled(capability)
        return Button {
            Task {
                busy = capability
                let ok = await app.capabilities.setEnabled(capability, !enabled)
                busy = nil
                if ok != enabled {
                    toast = ok ? "\(capability.title) 已开启" : "\(capability.title) 已关闭"
                } else if !ok, !enabled {
                    toast = app.capabilities.lastError ?? "没有拿到权限"
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: capability.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(enabled ? PogentTheme.accent : .secondary)
                    Spacer()
                    if busy == capability {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(enabled ? PogentTheme.accent : Color.white.opacity(0.2))
                    }
                }
                Text(capability.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(capability.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(enabled ? PogentTheme.accent.opacity(0.10) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(enabled ? PogentTheme.accent.opacity(0.35) : Color.white.opacity(0.07), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 快捷入口

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("随用随走")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 10) {
                Button { showVoice = true } label: {
                    quickCell("语音对话", "按住说，松开执行", "waveform.circle.fill", PogentTheme.accent)
                }
                .buttonStyle(.plain)

                Button { showScanner = true } label: {
                    quickCell("拍照识字", "OCR、扫码、文档", "camera.viewfinder", PogentTheme.violet)
                }
                .buttonStyle(.plain)

                NavigationLink { FilesView() } label: {
                    quickCell("文件", "浏览工作区与预览", "folder.fill", PogentTheme.amber)
                }
                .buttonStyle(.plain)

                NavigationLink { LibraryView() } label: {
                    quickCell("技能与审计", "重放任务、查回放", "square.stack.3d.up.fill", PogentTheme.rose)
                }
                .buttonStyle(.plain)

                NavigationLink { MemoryView() } label: {
                    quickCell("记忆", "它记住的事", "brain.head.profile", PogentTheme.accent)
                }
                .buttonStyle(.plain)

                NavigationLink { ConnectorsView() } label: {
                    quickCell("连接器", "GitHub、Notion、RSS", "link.circle.fill", PogentTheme.violet)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func quickCell(_ title: String, _ subtitle: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .glassCard(cornerRadius: 14)
    }

    // MARK: 工具清单

    private var toolList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("全部工具")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(filteredTools.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("搜工具名或说明", text: $search)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassCard(cornerRadius: 12)

            ForEach(ExecutionSurface.allCases, id: \.self) { surface in
                let tools = filteredTools.filter { $0.surface == surface }
                if !tools.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(PogentTheme.surfaceColor(surface)).frame(width: 6, height: 6)
                            Text(surface.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PogentTheme.surfaceColor(surface))
                            Text("\(tools.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(tools, id: \.name) { definition in
                            HStack(alignment: .top, spacing: 8) {
                                Text(definition.name)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .frame(width: 108, alignment: .leading)
                                Text(definition.summary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Circle()
                                    .fill(PogentTheme.riskColor(definition.risk))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 5)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(12)
                    .glassCard(cornerRadius: 14)
                }
            }
        }
    }

    private var filteredTools: [ToolDefinition] {
        let all = app.registry.order.compactMap { app.registry.definition(named: $0) }
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.summary.localizedCaseInsensitiveContains(search)
        }
    }
}

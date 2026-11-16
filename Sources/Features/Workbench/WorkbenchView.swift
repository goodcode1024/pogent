import SwiftUI
import WebKit

enum WorkbenchTab: String, CaseIterable, Identifiable {
    case terminal = "终端"
    case files = "文件"
    case diff = "改动"
    case browser = "浏览器"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .terminal: "chevron.left.forwardslash.chevron.right"
        case .files: "folder"
        case .diff: "plus.forwardslash.minus"
        case .browser: "globe"
        }
    }
}

struct WorkbenchView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var tab: WorkbenchTab = .terminal
    @State private var command = ""
    @State private var files: [WorkspaceFile] = []
    @State private var showRuntime = false

    var body: some View {
        ZStack {
            PogentTheme.background
            VStack(spacing: 12) {
                header
                Picker("", selection: $tab) {
                    ForEach(WorkbenchTab.allCases) { item in
                        Label(item.rawValue, systemImage: item.icon).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)

                Group {
                    switch tab {
                    case .terminal: terminal
                    case .files: fileList
                    case .diff: diffView
                    case .browser: browserView
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .task { reloadFiles() }
        .sheet(isPresented: $showRuntime) { RuntimeSheet() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("工作台")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("终端、文件、改动、浏览器，一个面板。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showRuntime = true
            } label: {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PogentTheme.accent)
                    .padding(9)
                    .background(PogentTheme.accent.opacity(0.12), in: Circle())
            }
        }
        .padding(.horizontal, 18)
    }

    // MARK: 终端

    private var terminal: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("pogent runtime · bash (builtin) · \(app.shell.cwd.lastPathComponent)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 4)

                        ForEach(Array(app.shell.transcript.enumerated()), id: \.offset) { _, block in
                            Text(block)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Color.clear.frame(height: 1).id("term-bottom")
                    }
                    .padding(14)
                }
                .onChange(of: app.shell.transcript.count) { _, _ in
                    withAnimation { proxy.scrollTo("term-bottom", anchor: .bottom) }
                }
            }

            HStack(spacing: 6) {
                Text("$").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(PogentTheme.accent)
                TextField("ls", text: $command)
                    .font(.system(size: 12, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(runCommand)
                Button(action: runCommand) {
                    Image(systemName: "return").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PogentTheme.ink)
                        .padding(6)
                        .background(PogentTheme.accent, in: Circle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.05))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 18)
    }

    private func runCommand() {
        let line = command
        command = ""
        Task {
            _ = await app.shell.run(line)
            reloadFiles()
        }
    }

    // MARK: 文件

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(app.shell.cwd.path.replacingOccurrences(of: app.shell.workspace.path, with: "~/Pogent"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        reloadFiles()
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                }
                .padding(.bottom, 4)

                if files.isEmpty {
                    Text("工作区是空的。让 agent 写点东西，或在终端里 touch 一个文件。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                }

                ForEach(files) { file in
                    HStack(spacing: 10) {
                        Image(systemName: file.isDirectory ? "folder.fill" : "doc.text")
                            .font(.system(size: 13))
                            .foregroundStyle(file.isDirectory ? PogentTheme.amber : PogentTheme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).font(.system(size: 12, weight: .medium))
                            Text(file.isDirectory ? "文件夹" : ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    Divider().opacity(0.2)
                }
            }
            .padding(14)
        }
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 18)
    }

    private func reloadFiles() {
        let url = app.shell.cwd
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        files = items.map { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            return WorkspaceFile(
                name: item.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: values?.fileSize ?? 0
            )
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: 改动

    private var diffView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("账单汇总.md").font(.system(size: 12, weight: .medium, design: .monospaced))
                    Spacer()
                    Text("+18  −3").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(12)

                ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 8) {
                        Text(line.marker)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(line.color)
                            .frame(width: 10)
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.color)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(line.color.opacity(0.07))
                }
            }
            .padding(.bottom, 12)
        }
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 18)
    }

    private var diffLines: [(marker: String, text: String, color: Color)] {
        [
            (" ", "# 十月外卖账单", .secondary),
            ("+", "| 日期 | 店铺 | 金额 |", PogentTheme.accent),
            ("+", "| 10-03 | 兰州拉面 | ¥28 |", PogentTheme.accent),
            ("+", "| 10-09 | 麦当劳 | ¥42 |", PogentTheme.accent),
            ("-", "| 合计 | 待补充 |", PogentTheme.rose),
            ("+", "| 合计 | ¥70 |", PogentTheme.accent)
        ]
    }

    // MARK: 浏览器

    private var browserView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(app.browser.tabs[app.browser.currentTabIndex].title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if app.browser.isLoading { ProgressView().controlSize(.mini) }
                Button { app.browser.goBack() } label: { Image(systemName: "chevron.left").font(.system(size: 11)) }
                Button { app.browser.newTab() } label: { Image(systemName: "plus").font(.system(size: 11)) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            WebViewContainer(webView: app.browser.webView)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(8)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 18)
    }
}

struct WorkspaceFile: Identifiable {
    var id: String { name }
    var name: String
    var isDirectory: Bool
    var size: Int
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 运行时

struct RuntimeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("内置引擎") {
                    ForEach(RuntimeDescriptor.all) { runtime in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(runtime.displayName).font(.system(size: 14, weight: .medium))
                                Text("\(runtime.version) · \(runtime.commands.joined(separator: " / "))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(runtime.isBundled ? "已就绪" : "未打包")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(runtime.isBundled ? PogentTheme.accent : .secondary)
                        }
                    }
                }
                Section("说明") {
                    Text("这些运行时以动态框架编进 App，和 Fish Pocket 的做法一致。仓库不含二进制，构建前把框架放进 Frameworks/ 即可。文件与终端在未接入时仍可用内置的 bash 子集。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("运行时")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

import SwiftUI
import SwiftData
import VisionKit
import PhotosUI

/// 拍照 / 相册 / 扫描文档 → 本机 OCR 和条码识别。
struct ScannerView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var text = ""
    @State private var codes: [String] = []
    @State private var labels: [String] = []
    @State private var savedPath: String?
    @State private var busy = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showDocuments = false
    @State private var showShare = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ZStack {
                PogentTheme.background
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        preview
                        sourceButtons
                        if busy { loading }
                        if !text.isEmpty || !codes.isEmpty { resultCards }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("看图和扫码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    ToastView(text: toast).padding(.top, 8)
                        .task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            withAnimation { self.toast = nil }
                        }
                }
            }
            .sheet(isPresented: $showCamera) {
                ImagePicker(source: .camera) { picked in handle(picked) }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showLibrary) {
                ImagePicker(source: .photoLibrary) { picked in handle(picked) }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showDocuments) {
                DocumentScanner { scanned in handle(scanned) }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [text])
            }
        }
    }

    // MARK: 预览

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.04))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("拍一张，或从相册选一张")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 220)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
        )
    }

    private var sourceButtons: some View {
        HStack(spacing: 10) {
            sourceButton("拍照", "camera.fill", PogentTheme.accent) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showCamera = true
                } else {
                    toast = "这台设备没有可用的相机，用相册试试"
                }
            }
            sourceButton("相册", "photo.on.rectangle", PogentTheme.violet) {
                showLibrary = true
            }
            sourceButton("扫描文档", "doc.viewfinder", PogentTheme.amber) {
                if VNDocumentCameraViewController.isSupported {
                    showDocuments = true
                } else {
                    toast = "这台设备不支持文档扫描"
                }
            }
        }
    }

    private func sourceButton(_ title: String, _ icon: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .glassCard(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("本机识别中…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: 结果

    private var resultCards: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !codes.isEmpty {
                SectionCard("条码", subtitle: nil, icon: "barcode") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(codes, id: \.self) { code in
                            Text(code)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !labels.isEmpty {
                SectionCard("画面内容", subtitle: nil, icon: "eye") {
                    Text(labels.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if !text.isEmpty {
                SectionCard("识别到的文字", subtitle: "\(text.count) 字", icon: "text.viewfinder") {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)

                    HStack(spacing: 8) {
                        actionButton("复制", "doc.on.doc") {
                            UIPasteboard.general.string = text
                            toast = "已复制"
                        }
                        actionButton("分享", "square.and.arrow.up") { showShare = true }
                        actionButton("问 pogent", "sparkles") { askAgent() }
                    }
                }
            }
        }
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 处理

    private func handle(_ picked: UIImage) {
        image = picked
        busy = true
        let analysis = VisionService.analyze(picked)
        text = analysis.text.joined(separator: "\n")
        codes = analysis.barcodes
        labels = analysis.labels.map { "\($0.0) \(Int($0.1 * 100))%" }
        savedPath = save(picked)
        busy = false
        if text.isEmpty && codes.isEmpty {
            toast = "这张图里没有文字和条码"
        } else {
            Presentation.success()
        }
    }

    private func save(_ image: UIImage) -> String? {
        let directory = app.workspaceURL.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "shot-\(formatter.string(from: Date())).jpg"
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        try? data.write(to: directory.appendingPathComponent(name))
        return "shots/\(name)"
    }

    private func askAgent() {
        let conversation = app.bootstrapConversation()
        let prompt: String
        if let savedPath {
            prompt = "看一下 \(savedPath)，用一句话告诉我这是什么，再把我需要的信息提取出来。"
        } else {
            prompt = "我拍到的内容：\n\(text)\n帮我整理一下。"
        }
        dismiss()
        Task {
            await app.runtime.submit(prompt, conversation: conversation, context: context)
        }
    }
}

// MARK: - 相机 / 相册

struct ImagePicker: UIViewControllerRepresentable {
    enum Source { case camera, photoLibrary }

    var source: Source
    var onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = source == .camera ? .camera : .photoLibrary
        if source == .camera { controller.cameraCaptureMode = .photo }
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage) -> Void
        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onPick(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - 文档扫描

struct DocumentScanner: UIViewControllerRepresentable {
    var onScan: (UIImage) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: (UIImage) -> Void
        init(onScan: @escaping (UIImage) -> Void) { self.onScan = onScan }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            if scan.pageCount > 0 {
                onScan(scan.imageOfPage(at: 0))
            }
            controller.dismiss(animated: true)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            controller.dismiss(animated: true)
        }
    }
}

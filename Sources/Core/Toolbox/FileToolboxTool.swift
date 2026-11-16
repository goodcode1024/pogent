import Foundation
import UIKit
import PDFKit
import CoreImage
import CoreImage.CIFilterBuiltins
@preconcurrency import Photos

/// 文件级工具：PDF 合并/拆分/提取、二维码生成、图片处理。
@MainActor
final class FileToolboxTool: AgentTool {
    private let workspace: URL

    init(workspace: URL) { self.workspace = workspace }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "media_toolbox",
            summary: """
            本地文件处理，action 取：
            pdf_merge 合并 PDF、pdf_text 提取文字、pdf_from_images 图片转 PDF、pdf_split 拆页、
            qr 生成二维码、image 缩放/裁剪/滤镜/转格式。
            """,
            surface: .native,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("pdf_merge | pdf_text | pdf_from_images | pdf_split | qr | image"),
                "paths": .arrayParam("输入文件（相对工作区）"),
                "output": .stringParam("输出文件（相对工作区）"),
                "text": .stringParam("qr 的内容"),
                "page": .numberParam("pdf_split 的页码，从 0 开始"),
                "width": .numberParam("image 的目标宽度"),
                "quality": .numberParam("JPEG 质量 0–1，默认 0.85"),
                "filter": .stringParam("滤镜：mono / sepia / invert / blur / sharpen"),
                "scale": .numberParam("二维码放大倍数，默认 10")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let action = arguments["action"]?.stringValue ?? ""
        let paths = (arguments["paths"]?.arrayValue ?? []).compactMap(\.stringValue)

        switch action {
        case "pdf_merge":
            guard paths.count >= 2 else { throw ToolError.badInput("至少给两个 PDF") }
            let merged = PDFDocument()
            var index = 0
            for path in paths {
                guard let document = PDFDocument(url: workspace.appendingPathComponent(path)) else {
                    throw ToolError.badInput("打不开 \(path)")
                }
                for pageIndex in 0..<document.pageCount {
                    guard let page = document.page(at: pageIndex) else { continue }
                    merged.insert(page, at: index)
                    index += 1
                }
            }
            let output = arguments["output"]?.stringValue ?? "合并.pdf"
            let url = workspace.appendingPathComponent(output)
            guard merged.write(to: url) else { throw ToolError.unavailable("写入失败") }
            return .ok("合并 \(index) 页到 \(output)")

        case "pdf_text":
            guard let path = paths.first else { throw ToolError.badInput("缺少 paths") }
            guard let document = PDFDocument(url: workspace.appendingPathComponent(path)) else {
                throw ToolError.badInput("打不开 \(path)")
            }
            var text = ""
            for pageIndex in 0..<document.pageCount {
                text += document.page(at: pageIndex)?.string ?? ""
                text += "\n"
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .ok(trimmed.isEmpty ? "这份 PDF 没有可提取的文字（可能是扫描件，试用 ocr）" : String(trimmed.prefix(6000)))

        case "pdf_from_images":
            guard !paths.isEmpty else { throw ToolError.badInput("缺少 paths") }
            let document = PDFDocument()
            for (index, path) in paths.enumerated() {
                guard let image = VisionService.loadImage(path: workspace.appendingPathComponent(path)),
                      let page = PDFPage(image: image) else { continue }
                document.insert(page, at: index)
            }
            let output = arguments["output"]?.stringValue ?? "相册.pdf"
            guard document.write(to: workspace.appendingPathComponent(output)) else {
                throw ToolError.unavailable("写入失败")
            }
            return .ok("生成 \(document.pageCount) 页 PDF：\(output)")

        case "pdf_split":
            guard let path = paths.first else { throw ToolError.badInput("缺少 paths") }
            guard let document = PDFDocument(url: workspace.appendingPathComponent(path)) else {
                throw ToolError.badInput("打不开 \(path)")
            }
            let page = Int(arguments["page"]?.numberValue ?? 0)
            guard let source = document.page(at: page) else { throw ToolError.badInput("没有第 \(page) 页") }
            let output = arguments["output"]?.stringValue ?? "第\(page)页.pdf"
            let single = PDFDocument()
            single.insert(source, at: 0)
            guard single.write(to: workspace.appendingPathComponent(output)) else {
                throw ToolError.unavailable("写入失败")
            }
            return .ok("已导出第 \(page) 页到 \(output)")

        case "qr":
            guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
                throw ToolError.badInput("缺少 text")
            }
            let scale = max(arguments["scale"]?.numberValue ?? 10, 1)
            let output = arguments["output"]?.stringValue ?? "qr-\(Int(Date().timeIntervalSince1970)).png"
            let url = try QRCode.write(text, scale: CGFloat(scale), to: workspace.appendingPathComponent(output))
            return .ok("二维码已保存：\(url.lastPathComponent)", payload: .object(["path": .string(url.lastPathComponent)]))

        case "image":
            guard let path = paths.first else { throw ToolError.badInput("缺少 paths") }
            let source = workspace.appendingPathComponent(path)
            guard let image = VisionService.loadImage(path: source) else {
                throw ToolError.badInput("读不到图片：\(path)")
            }
            let output = arguments["output"]?.stringValue
                ?? (source.deletingPathExtension().lastPathComponent + "-out.jpg")
            let width = arguments["width"]?.numberValue
            let quality = arguments["quality"]?.numberValue ?? 0.85
            let filter = arguments["filter"]?.stringValue

            var processed = image
            if let width, width > 0 {
                processed = ImageProcessor.resized(processed, width: CGFloat(width))
            }
            if let filter, !filter.isEmpty {
                processed = ImageProcessor.apply(filter, to: processed) ?? processed
            }
            let url = workspace.appendingPathComponent(output)
            guard let data = processed.jpegData(compressionQuality: quality) else {
                throw ToolError.unavailable("编码失败")
            }
            try data.write(to: url)
            return .ok("已保存 \(output)（\(Int(processed.size.width))×\(Int(processed.size.height))，\(data.count / 1024) KB）")

        default:
            throw ToolError.badInput("未知动作：\(action)")
        }
    }
}

enum QRCode {
    static func make(_ text: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    @discardableResult
    static func write(_ text: String, scale: CGFloat, to url: URL) throws -> URL {
        guard let image = make(text, scale: scale),
              let data = image.pngData() else {
            throw ToolError.unavailable("二维码生成失败")
        }
        try data.write(to: url)
        return url
    }
}

enum ImageProcessor {
    static func resized(_ image: UIImage, width: CGFloat) -> UIImage {
        let ratio = width / max(image.size.width, 1)
        let size = CGSize(width: width, height: image.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func cropped(_ image: UIImage, to rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = image.scale
        let scaled = CGRect(
            x: rect.origin.x * scale, y: rect.origin.y * scale,
            width: rect.width * scale, height: rect.height * scale
        )
        guard let cropped = cgImage.cropping(to: scaled) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: image.imageOrientation)
    }

    static func apply(_ name: String, to image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let filter: CIFilter?
        switch name.lowercased() {
        case "mono": filter = CIFilter(name: "CIPhotoEffectMono")
        case "sepia": filter = CIFilter(name: "CISepiaTone", parameters: [kCIInputIntensityKey: 0.8])
        case "invert": filter = CIFilter(name: "CIColorInvert")
        case "blur": filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 8])
        case "sharpen": filter = CIFilter(name: "CISharpenLuminance", parameters: [kCIInputSharpnessKey: 1.2])
        default: filter = nil
        }
        guard let filter else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        let rect = name.lowercased() == "blur" ? input.extent : output.extent
        guard let result = context.createCGImage(output, from: rect) else { return nil }
        return UIImage(cgImage: result)
    }

    static func saveToPhotoLibrary(_ image: UIImage) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

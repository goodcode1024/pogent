import Foundation
import UIKit
@preconcurrency import Vision
import ImageIO

/// 本机视觉：文字识别、条码、图像分类、颜色。全部走系统框架，不联网。
enum VisionService {
    struct TextBlock: Sendable {
        var text: String
        var confidence: Float
    }

    struct Analysis: Sendable {
        var text: [String]
        var barcodes: [String]
        var labels: [(String, Double)]
        var averageColor: String
        var size: CGSize
    }

    static func loadImage(path: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return UIImage(data: data)
    }

    static func recognizeText(in image: UIImage) -> [TextBlock] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation(of: image), options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextBlock(text: candidate.string, confidence: candidate.confidence)
        }
    }

    static func detectBarcodes(in image: UIImage) -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation(of: image), options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }

    static func classify(_ image: UIImage) -> [(String, Double)] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation(of: image), options: [:])
        try? handler.perform([request])
        let results = (request.results ?? [])
            .filter { $0.confidence > 0.15 }
            .prefix(6)
            .map { ($0.identifier, Double($0.confidence)) }
        return Array(results)
    }

    static func analyze(_ image: UIImage) -> Analysis {
        let text = recognizeText(in: image).map(\.text)
        let codes = detectBarcodes(in: image)
        let labels = classify(image)
        return Analysis(
            text: text,
            barcodes: codes,
            labels: labels,
            averageColor: averageColorHex(of: image),
            size: image.size
        )
    }

    static func averageColorHex(of image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "#000000" }
        let width = 1, height = 1
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "#000000" }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }

    private static func orientation(of image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }

    /// 把识别结果整理成模型能读的短文本。
    static func digest(_ analysis: Analysis) -> String {
        var lines: [String] = []
        if !analysis.text.isEmpty {
            lines.append("文字：")
            lines.append(contentsOf: analysis.text.prefix(40).map { "  \($0)" })
        }
        if !analysis.barcodes.isEmpty {
            lines.append("条码：\(analysis.barcodes.joined(separator: "、"))")
        }
        if !analysis.labels.isEmpty {
            let labels = analysis.labels.map { "\($0.0) \(Int($0.1 * 100))%" }.joined(separator: "、")
            lines.append("画面：\(labels)")
        }
        lines.append("主色：\(analysis.averageColor)，尺寸：\(Int(analysis.size.width))×\(Int(analysis.size.height))")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 工具

@MainActor
final class OCRTool: AgentTool {
    private let workspace: URL

    init(workspace: URL) { self.workspace = workspace }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "ocr",
            summary: "识别图片里的文字（中英混排）。传工作区路径，结果同时写一份 txt 到同目录。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "path": .stringParam("相对工作区的图片路径，例如 shots/receipt.png"),
                "save": .boolParam("是否把结果存成同名 txt，默认 true")
            ], required: ["path"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let path = arguments["path"]?.stringValue else { throw ToolError.badInput("缺少 path") }
        let url = workspace.appendingPathComponent(path)
        guard let image = VisionService.loadImage(path: url) else {
            throw ToolError.badInput("读不到图片：\(path)")
        }
        let blocks = VisionService.recognizeText(in: image)
        guard !blocks.isEmpty else { return .ok("这张图里没有识别到文字") }

        let text = blocks.map(\.text).joined(separator: "\n")
        if arguments["save"]?.boolValue ?? true {
            let out = url.deletingPathExtension().appendingPathExtension("txt")
            try? text.write(to: out, atomically: true, encoding: .utf8)
        }
        return .ok("识别到 \(blocks.count) 行文字", payload: .object([
            "text": .string(text),
            "lines": .number(Double(blocks.count))
        ]))
    }
}

@MainActor
final class ScanCodeTool: AgentTool {
    private let workspace: URL

    init(workspace: URL) { self.workspace = workspace }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "scan_code",
            summary: "从图片里读二维码 / 条形码内容（支持链接、WiFi、名片、支付码）。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "path": .stringParam("相对工作区的图片路径")
            ], required: ["path"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let path = arguments["path"]?.stringValue else { throw ToolError.badInput("缺少 path") }
        guard let image = VisionService.loadImage(path: workspace.appendingPathComponent(path)) else {
            throw ToolError.badInput("读不到图片：\(path)")
        }
        let codes = VisionService.detectBarcodes(in: image)
        guard !codes.isEmpty else { return .ok("没有发现二维码或条码") }
        return .ok(codes.joined(separator: "\n"), payload: .object([
            "codes": .array(codes.map { .string($0) })
        ]))
    }
}

/// 看图：文字 + 条码 + 画面分类 + 主色。给模型提供“看见”的能力。
@MainActor
final class SeeTool: AgentTool {
    private let workspace: URL

    init(workspace: URL) { self.workspace = workspace }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "see",
            summary: "看一张图：提取文字、条码、画面内容标签和主色。相当于本机视觉。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "path": .stringParam("相对工作区的图片路径")
            ], required: ["path"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let path = arguments["path"]?.stringValue else { throw ToolError.badInput("缺少 path") }
        guard let image = VisionService.loadImage(path: workspace.appendingPathComponent(path)) else {
            throw ToolError.badInput("读不到图片：\(path)")
        }
        let analysis = VisionService.analyze(image)
        let digest = VisionService.digest(analysis)
        return .ok(digest, payload: .object([
            "text": .array(analysis.text.map { .string($0) }),
            "barcodes": .array(analysis.barcodes.map { .string($0) }),
            "labels": .array(analysis.labels.map { .string($0.0) }),
            "averageColor": .string(analysis.averageColor)
        ]))
    }
}

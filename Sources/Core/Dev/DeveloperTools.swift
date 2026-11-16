import Foundation

// MARK: - 终端

@MainActor
final class ShellTool: AgentTool {
    private let shell: ShellSession

    init(shell: ShellSession) { self.shell = shell }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "shell",
            summary: "在工作区执行一条 shell 命令（内置 bash 子集，可接入 node/python/git/ffmpeg）。",
            surface: .shell,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "command": .stringParam("要执行的命令"),
                "timeout_seconds": .numberParam("超时秒数，默认 30")
            ], required: ["command"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let command = arguments["command"]?.stringValue else { throw ToolError.badInput("缺少 command") }
        let timeout = Int((arguments["timeout_seconds"]?.doubleValue ?? 30) * 1000)
        let result = await shell.run(command, timeout: .milliseconds(max(timeout, 1000)))

        let text = """
        $ \(command)
        退出码: \(result.exitCode)
        \(result.combined.isEmpty ? "(无输出)" : String(result.combined.prefix(8000)))
        """
        return ToolOutcome(
            status: result.isSuccess ? .ok : .failed,
            summary: "\(command) → \(result.exitCode)",
            payload: .object([
                "exit_code": .number(Double(result.exitCode)),
                "stdout": .string(String(result.stdout.prefix(20000))),
                "stderr": .string(String(result.stderr.prefix(4000)))
            ]),
            modelText: text
        )
    }
}

// MARK: - 读文件

@MainActor
final class ReadFileTool: AgentTool {
    private let shell: ShellSession

    init(shell: ShellSession) { self.shell = shell }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "read_file",
            summary: "读工作区里的文本文件，可指定行区间。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "path": .stringParam("相对路径"),
                "start_line": .numberParam("起始行，默认 1"),
                "line_count": .numberParam("读多少行，默认 400")
            ], required: ["path"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let path = arguments["path"]?.stringValue else { throw ToolError.badInput("缺少 path") }
        let url = shell.resolve(path)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .failed("读不到 \(path)")
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max((arguments["start_line"]?.intValue ?? 1) - 1, 0)
        let count = arguments["line_count"]?.intValue ?? 400
        let slice = lines.dropFirst(start).prefix(count)
        let numbered = slice.enumerated().map { "\(start + $0.offset + 1)\t\($0.element)" }.joined(separator: "\n")
        return .ok("读了 \(slice.count) 行", payload: .object(["path": .string(path)]), modelText: numbered)
    }
}

// MARK: - 写文件

@MainActor
final class WriteFileTool: AgentTool {
    private let shell: ShellSession

    init(shell: ShellSession) { self.shell = shell }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "write_file",
            summary: "写文本文件，或替换其中的一段。append=true 时追加。",
            surface: .native,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "path": .stringParam("相对路径"),
                "content": .stringParam("要写入的内容"),
                "append": .boolParam("追加而不是覆盖"),
                "find": .stringParam("可选：要替换的原文"),
                "replace": .stringParam("可选：替换成")
            ], required: ["path", "content"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let path = arguments["path"]?.stringValue,
              let content = arguments["content"]?.stringValue else {
            throw ToolError.badInput("需要 path 和 content")
        }
        let url = shell.resolve(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let find = arguments["find"]?.stringValue, let replace = arguments["replace"]?.stringValue {
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
                return .failed("文件不存在：\(path)")
            }
            guard existing.contains(find) else { return .failed("没有找到要替换的内容") }
            let updated = existing.replacingOccurrences(of: find, with: replace)
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return .ok("已替换 \(path) 里的内容")
        }

        if arguments["append"]?.boolValue == true,
           let existing = try? String(contentsOf: url, encoding: .utf8) {
            try (existing + content).write(to: url, atomically: true, encoding: .utf8)
            return .ok("已追加到 \(path)")
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
        return .ok("已写入 \(path)（\(content.count) 字符）")
    }
}

// MARK: - 列出文件

@MainActor
final class ListFilesTool: AgentTool {
    private let shell: ShellSession

    init(shell: ShellSession) { self.shell = shell }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "list_files",
            summary: "列出目录内容，带大小和修改时间。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "path": .stringParam("目录，默认当前目录")
            ])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let url = shell.resolve(arguments["path"]?.stringValue ?? ".")
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else {
            return .failed("读不到目录 \(url.lastPathComponent)")
        }
        let lines = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item -> String in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let size = values?.fileSize ?? 0
            return "\(isDir ? "d" : "-") \(String(format: "%8d", size))  \(item.lastPathComponent)"
        }
        return .ok("\(items.count) 项", modelText: lines.joined(separator: "\n"))
    }
}

// MARK: - Git

@MainActor
final class GitTool: AgentTool {
    private let shell: ShellSession

    init(shell: ShellSession) { self.shell = shell }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "git",
            summary: "在工作区执行 git 子命令，例如 status / diff / log / commit。",
            surface: .shell,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "args": .stringParam("git 后面的参数，例如 status --short")
            ], required: ["args"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let args = arguments["args"]?.stringValue else { throw ToolError.badInput("缺少 args") }
        let result = await shell.run("git \(args)")
        return ToolOutcome(
            status: result.isSuccess ? .ok : .failed,
            summary: "git \(args)",
            payload: .object(["exit_code": .number(Double(result.exitCode))]),
            modelText: result.combined.isEmpty ? "(无输出)" : String(result.combined.prefix(6000))
        )
    }
}

// MARK: - 媒体

@MainActor
final class MediaTool: AgentTool {
    private let shell: ShellSession

    init(shell: ShellSession) { self.shell = shell }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "media",
            summary: "用 ffmpeg 处理音视频：抽帧、转码、剪辑、抽音轨。",
            surface: .shell,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "args": .stringParam("ffmpeg 参数，例如 -i in.mov -vf fps=1 out-%03d.jpg")
            ], required: ["args"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let args = arguments["args"]?.stringValue else { throw ToolError.badInput("缺少 args") }
        let result = await shell.run("ffmpeg \(args)")
        return ToolOutcome(
            status: result.isSuccess ? .ok : .failed,
            summary: "ffmpeg 处理完成",
            payload: .object(["exit_code": .number(Double(result.exitCode))]),
            modelText: String(result.combined.suffix(4000))
        )
    }
}

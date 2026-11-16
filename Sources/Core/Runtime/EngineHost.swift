import Foundation
import Observation

// MARK: - 结果

struct CommandResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var duration: TimeInterval

    var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var isSuccess: Bool { exitCode == 0 }
}

// MARK: - 运行时

/// 外部运行时（Node / Python / Git / FFmpeg）。
///
/// Fish Pocket 的做法是把 nodejs-mobile、CPython、libgit2、FFmpeg 以动态框架
/// 编进 App，每个“进程”其实是 App 里的线程 + 独立管道。
/// 这个仓库不含那些二进制，接入时把它们放进 `Frameworks/` 并在
/// `RuntimeBundle` 里登记即可；pogent 的引擎接口与 Fish Pocket 对齐。
struct RuntimeDescriptor: Sendable, Identifiable {
    var id: String
    var displayName: String
    var frameworkName: String
    var version: String
    var commands: [String]

    var isBundled: Bool {
        Bundle.main.url(forResource: frameworkName, withExtension: "framework") != nil
            || FileManager.default.fileExists(atPath: Self.frameworksDirectory.appendingPathComponent("\(frameworkName).framework").path)
    }

    static let frameworksDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pogent/Frameworks", isDirectory: true)

    static let all: [RuntimeDescriptor] = [
        .init(id: "node", displayName: "Node.js", frameworkName: "nodejs-mobile", version: "24", commands: ["node", "pnpm", "npx"]),
        .init(id: "python", displayName: "Python", frameworkName: "Python", version: "3.15", commands: ["python3", "pip", "venv"]),
        .init(id: "git", displayName: "Git", frameworkName: "libgit2", version: "1.9", commands: ["git"]),
        .init(id: "ffmpeg", displayName: "FFmpeg", frameworkName: "FFmpeg", version: "9.0", commands: ["ffmpeg", "ffprobe"])
    ]
}

// MARK: - 引擎

/// 会话级 shell。工作目录被限制在 Pogent 的沙箱工作区里。
@MainActor
@Observable
final class ShellSession {
    private(set) var cwd: URL
    let workspace: URL
    private(set) var history: [String] = []
    private(set) var transcript: [String] = []
    private(set) var isRunning = false

    /// 外部运行时转发。接入真实框架后由它执行 node / python / git / ffmpeg。
    @ObservationIgnored var externalRunner: ((String, URL) async throws -> CommandResult)?

    init(workspace: URL) {
        self.workspace = workspace
        self.cwd = workspace
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func reset() {
        cwd = workspace
        transcript.removeAll()
    }

    func run(_ line: String, timeout: Duration = .seconds(30)) async -> CommandResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CommandResult(exitCode: 0, stdout: "", stderr: "", duration: 0) }
        history.append(trimmed)
        isRunning = true
        defer { isRunning = false }

        let started = Date()
        let result: CommandResult
        do {
            result = try await execute(trimmed)
        } catch {
            result = CommandResult(exitCode: 127, stdout: "", stderr: error.localizedDescription, duration: Date().timeIntervalSince(started))
        }

        transcript.append("$ \(trimmed)\n\(result.combined)")
        if transcript.count > 200 { transcript.removeFirst(transcript.count - 200) }
        return result
    }

    // MARK: 分发

    private func execute(_ line: String) async throws -> CommandResult {
        let parts = Self.split(line)
        guard let command = parts.first else {
            return CommandResult(exitCode: 0, stdout: "", stderr: "", duration: 0)
        }
        let args = Array(parts.dropFirst())
        let started = Date()

        switch command {
        case "pwd":
            return ok(cwd.path, started)
        case "cd":
            let target = args.first ?? "~"
            let url = resolve(target)
            guard FileManager.default.fileExists(atPath: url.path) else { return fail("cd: no such directory: \(target)", started) }
            cwd = url
            return ok("", started)
        case "ls":
            let url = resolve(args.last ?? ".")
            let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path).sorted()) ?? []
            return ok(items.joined(separator: "  "), started)
        case "cat":
            guard let path = args.first else { return fail("cat: missing operand", started) }
            let url = resolve(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return fail("cat: \(path): No such file", started) }
            return ok(text, started)
        case "echo":
            return ok(args.joined(separator: " "), started)
        case "mkdir":
            guard let path = args.last else { return fail("mkdir: missing operand", started) }
            try FileManager.default.createDirectory(at: resolve(path), withIntermediateDirectories: true)
            return ok("", started)
        case "touch":
            guard let path = args.last else { return fail("touch: missing operand", started) }
            FileManager.default.createFile(atPath: resolve(path).path, contents: nil)
            return ok("", started)
        case "rm":
            let force = args.contains("-rf") || args.contains("-f")
            guard let path = args.last, path != "-rf", path != "-f" else { return fail("rm: missing operand", started) }
            do {
                try FileManager.default.removeItem(at: resolve(path))
                return ok("", started)
            } catch {
                return force ? ok("", started) : fail("rm: \(path): \(error.localizedDescription)", started)
            }
        case "cp", "mv":
            guard args.count >= 2 else { return fail("\(command): missing operand", started) }
            let from = resolve(args[0]), to = resolve(args[1])
            do {
                if command == "cp" { try FileManager.default.copyItem(at: from, to: to) }
                else { try FileManager.default.moveItem(at: from, to: to) }
                return ok("", started)
            } catch {
                return fail("\(command): \(error.localizedDescription)", started)
            }
        case "wc":
            guard let path = args.last, let text = try? String(contentsOf: resolve(path), encoding: .utf8) else {
                return fail("wc: missing file", started)
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            return ok("\(lines)\t\(text.count)\t\(path)", started)
        case "grep":
            guard args.count >= 2 else { return fail("grep: usage: grep pattern file", started) }
            let pattern = args[0]
            guard let text = try? String(contentsOf: resolve(args[1]), encoding: .utf8) else {
                return fail("grep: \(args[1]): No such file", started)
            }
            let hits = text.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(pattern) }
            return CommandResult(exitCode: hits.isEmpty ? 1 : 0, stdout: hits.prefix(200).joined(separator: "\n"),
                                 stderr: "", duration: Date().timeIntervalSince(started))
        case "node", "python3", "pip", "git", "ffmpeg", "ffprobe", "pnpm":
            if let externalRunner {
                return try await externalRunner(line, cwd)
            }
            let descriptor = RuntimeDescriptor.all.first { $0.commands.contains(command) }
            let name = descriptor?.displayName ?? command
            return fail("\(command): \(name) 运行时没有随这个仓库分发。把 \(descriptor?.frameworkName ?? command) 放进 Frameworks/ 后即可用。", started)
        default:
            return fail("\(command): command not found（内置支持 ls/cd/pwd/cat/echo/mkdir/touch/rm/cp/mv/wc/grep）", started)
        }
    }

    // MARK: 工具

    func resolve(_ path: String) -> URL {
        if path == "~" || path == "/" { return workspace }
        if path.hasPrefix("/") {
            // 绝对路径也映射到工作区，避免逃出沙箱。
            return workspace.appendingPathComponent(String(path.dropFirst()))
        }
        return cwd.appendingPathComponent(path).standardizedFileURL
    }

    private func ok(_ output: String, _ started: Date) -> CommandResult {
        CommandResult(exitCode: 0, stdout: output, stderr: "", duration: Date().timeIntervalSince(started))
    }

    private func fail(_ message: String, _ started: Date) -> CommandResult {
        CommandResult(exitCode: 1, stdout: "", stderr: message, duration: Date().timeIntervalSince(started))
    }

    static func split(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        for character in line {
            switch character {
            case "'" where !inDouble:
                inSingle.toggle()
            case "\"" where !inSingle:
                inDouble.toggle()
            case " " where !inSingle && !inDouble:
                if !current.isEmpty { result.append(current); current = "" }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

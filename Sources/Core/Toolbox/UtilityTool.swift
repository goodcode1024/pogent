import Foundation
import CryptoKit

/// 不依赖网络也不依赖模型的本地工具：算数、单位、文本、正则、JSON、编码、哈希、日期。
@MainActor
final class UtilityTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "utility",
            summary: """
            本地小工具，action 取：
            calc 算数、convert 单位换算、date 日期计算、regex 正则、
            json JSON 整理、encode 编码解码、hash 哈希、text 文本处理、random 随机。
            """,
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("calc | convert | date | regex | json | encode | hash | text | random"),
                "expression": .stringParam("calc 的算式，例如 (128*3+96)/4"),
                "value": .numberParam("convert 的数值"),
                "from": .stringParam("原单位，例如 km / c / GB"),
                "to": .stringParam("目标单位"),
                "text": .stringParam("输入文本"),
                "pattern": .stringParam("正则"),
                "replacement": .stringParam("替换成什么"),
                "mode": .stringParam("encode: base64/url/hex/unicode；text: upper/lower/trim/count/reverse/slug；hash: md5/sha1/sha256"),
                "path": .stringParam("json 取值的路径，例如 data.items.0.name"),
                "days": .numberParam("date 加几天"),
                "count": .numberParam("random 生成几个，默认 1"),
                "min": .numberParam("random 最小值"),
                "max": .numberParam("random 最大值")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        let action = arguments["action"]?.stringValue ?? ""
        let text = arguments["text"]?.stringValue ?? ""

        switch action {
        case "calc":
            guard let expression = arguments["expression"]?.stringValue else {
                throw ToolError.badInput("缺少 expression")
            }
            let value = try Calculator.evaluate(expression)
            return .ok("\(expression) = \(Calculator.format(value))", payload: .object(["value": .number(value)]))

        case "convert":
            let value = arguments["value"]?.numberValue ?? 0
            let from = arguments["from"]?.stringValue ?? ""
            let to = arguments["to"]?.stringValue ?? ""
            let result = try UnitConverter.convert(value, from: from, to: to)
            return .ok("\(Calculator.format(value)) \(from) = \(Calculator.format(result)) \(to)",
                       payload: .object(["value": .number(result)]))

        case "date":
            return try dateAction(arguments)

        case "regex":
            guard let pattern = arguments["pattern"]?.stringValue else { throw ToolError.badInput("缺少 pattern") }
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let range = NSRange(text.startIndex..., in: text)
            if let replacement = arguments["replacement"]?.stringValue {
                let output = regex.stringByReplacingMatches(
                    in: text, options: [], range: range,
                    withTemplate: replacement
                )
                return .ok(output, payload: .object(["result": .string(output)]))
            }
            let matches = regex.matches(in: text, options: [], range: range).compactMap { match -> String? in
                guard let range = Range(match.range, in: text) else { return nil }
                return String(text[range])
            }
            return .ok(matches.isEmpty ? "没有匹配" : matches.joined(separator: "\n"),
                       payload: .object(["count": .number(Double(matches.count))]))

        case "json":
            return try jsonAction(arguments, text: text)

        case "encode":
            return try encodeAction(arguments, text: text)

        case "hash":
            let algorithm = (arguments["mode"]?.stringValue ?? "sha256").lowercased()
            let data = Data(text.utf8)
            let digest: String
            switch algorithm {
            case "md5": digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            case "sha1": digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
            default: digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            return .ok(digest, payload: .object(["hash": .string(digest)]))

        case "text":
            let mode = arguments["mode"]?.stringValue ?? "count"
            let output: String
            switch mode {
            case "upper": output = text.uppercased()
            case "lower": output = text.lowercased()
            case "trim": output = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "reverse": output = String(text.reversed())
            case "slug":
                output = text.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
                    .joined(separator: "-")
            default:
                let characters = text.count
                let words = text.split { $0.isWhitespace || $0.isPunctuation }.count
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                output = "\(characters) 字，\(words) 词，\(lines) 行"
            }
            return .ok(output, payload: .object(["result": .string(output)]))

        case "random":
            let count = min(max(Int(arguments["count"]?.numberValue ?? 1), 1), 50)
            let min = Int(arguments["min"]?.numberValue ?? 1)
            let max = Int(arguments["max"]?.numberValue ?? 100)
            guard min <= max else { throw ToolError.badInput("min 不能大于 max") }
            let values = (0..<count).map { _ in Int.random(in: min...max) }
            return .ok(values.map(String.init).joined(separator: ", "))

        default:
            throw ToolError.badInput("未知动作：\(action)")
        }
    }

    private func dateAction(_ arguments: JSONValue) throws -> ToolOutcome {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm EEEE"

        var base = Date()
        if let raw = arguments["text"]?.stringValue, !raw.isEmpty {
            if let parsed = DateParsing.date(raw) { base = parsed }
            else if let parsed = ClockTool.parseClock(raw) { base = parsed }
            else { throw ToolError.badInput("看不懂这个日期：\(raw)") }
        }

        if let days = arguments["days"]?.numberValue {
            base = Calendar.current.date(byAdding: .day, value: Int(days), to: base) ?? base
        }

        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: base)
        let week = calendar.component(.weekOfYear, from: base)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: base) ?? 0
        let isWeekend = weekday == 1 || weekday == 7
        let relative = Self.relative(base)

        return .ok("""
        \(formatter.string(from: base))
        第 \(week) 周 · 今年第 \(dayOfYear) 天 · \(isWeekend ? "周末" : "工作日")
        \(relative)
        """)
    }

    private func jsonAction(_ arguments: JSONValue, text: String) throws -> ToolOutcome {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            throw ToolError.badInput("这不是合法 JSON")
        }

        if let path = arguments["path"]?.stringValue, !path.isEmpty {
            var current: Any = object
            for key in path.split(separator: ".") {
                if let dictionary = current as? [String: Any], let next = dictionary[String(key)] {
                    current = next
                } else if let array = current as? [Any], let index = Int(key), index < array.count {
                    current = array[index]
                } else {
                    throw ToolError.badInput("路径不存在：\(path)")
                }
            }
            if let string = current as? String { return .ok(string) }
            if let number = current as? NSNumber { return .ok(number.stringValue) }
            if let nested = try? JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys]),
               let pretty = String(data: nested, encoding: .utf8) {
                return .ok(pretty)
            }
            return .ok(String(describing: current))
        }

        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return .ok(String(data: pretty, encoding: .utf8) ?? "{}")
    }

    private func encodeAction(_ arguments: JSONValue, text: String) throws -> ToolOutcome {
        let mode = arguments["mode"]?.stringValue ?? "base64"
        // 带 decode: 前缀表示反向。
        let isDecode = mode.hasPrefix("decode:")
        let kind = isDecode ? String(mode.dropFirst(7)) : mode

        switch kind {
        case "base64":
            if isDecode {
                guard let data = Data(base64Encoded: text),
                      let output = String(data: data, encoding: .utf8) else {
                    throw ToolError.badInput("不是合法的 Base64")
                }
                return .ok(output)
            }
            return .ok(Data(text.utf8).base64EncodedString())

        case "url":
            if isDecode {
                return .ok(text.removingPercentEncoding ?? text)
            }
            return .ok(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text)

        case "hex":
            if isDecode {
                var bytes: [UInt8] = []
                var index = text.startIndex
                while index < text.endIndex, let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) {
                    if let byte = UInt8(text[index..<next], radix: 16) { bytes.append(byte) }
                    index = next
                }
                return .ok(String(data: Data(bytes), encoding: .utf8) ?? "")
            }
            return .ok(Data(text.utf8).map { String(format: "%02x", $0) }.joined())

        case "unicode":
            if isDecode {
                let scalars = text.split(separator: " ").compactMap { UInt32($0, radix: 16) }
                return .ok(String(String.UnicodeScalarView(scalars.compactMap(UnicodeScalar.init))))
            }
            return .ok(text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))

        default:
            throw ToolError.badInput("不支持的编码：\(kind)")
        }
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 计算器

enum Calculator {
    /// 递归下降解析，支持 + - * / % ^ 括号、一元负号、百分比。
    static func evaluate(_ expression: String) throws -> Double {
        var parser = Parser(tokens: tokenize(expression))
        let value = try parser.expression()
        guard parser.isAtEnd else { throw ToolError.badInput("算式有多余内容：\(expression)") }
        guard value.isFinite else { throw ToolError.badInput("结果不是有限数") }
        return value
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.6g", value)
    }

    enum Token: Equatable {
        case number(Double)
        case op(Character)
        case left, right
    }

    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var number = ""
        for character in input {
            if character.isNumber || character == "." {
                number.append(character)
            } else if character == "," {
                continue
            } else {
                if !number.isEmpty {
                    if let value = Double(number) { tokens.append(.number(value)) }
                    number = ""
                }
                switch character {
                case "+", "-", "*", "/", "%", "^": tokens.append(.op(character))
                case "×", "x", "X": tokens.append(.op("*"))
                case "÷": tokens.append(.op("/"))
                case "（": tokens.append(.left)
                case "）": tokens.append(.right)
                case "(": tokens.append(.left)
                case ")": tokens.append(.right)
                case " ": break
                default: break
                }
            }
        }
        if !number.isEmpty, let value = Double(number) { tokens.append(.number(value)) }
        return tokens
    }

    struct Parser {
        let tokens: [Token]
        var index = 0

        var isAtEnd: Bool { index >= tokens.count }

        mutating func peek() -> Token? { isAtEnd ? nil : tokens[index] }

        mutating func expression() throws -> Double {
            var value = try term()
            while case .op(let op)? = peek(), op == "+" || op == "-" {
                index += 1
                let rhs = try term()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() throws -> Double {
            var value = try power()
            while case .op(let op)? = peek(), op == "*" || op == "/" || op == "%" {
                index += 1
                let rhs = try power()
                switch op {
                case "*": value *= rhs
                case "/":
                    guard rhs != 0 else { throw ToolError.badInput("不能除以 0") }
                    value /= rhs
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        mutating func power() throws -> Double {
            let base = try unary()
            if case .op("^")? = peek() {
                index += 1
                let exponent = try power()
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() throws -> Double {
            if case .op("-")? = peek() {
                index += 1
                return try unary() * -1
            }
            if case .op("+")? = peek() {
                index += 1
                return try unary()
            }
            return try primary()
        }

        mutating func primary() throws -> Double {
            guard let token = peek() else { throw ToolError.badInput("算式不完整") }
            switch token {
            case .number(let value):
                index += 1
                return value
            case .left:
                index += 1
                let value = try expression()
                guard case .right? = peek() else { throw ToolError.badInput("括号没有闭合") }
                index += 1
                return value
            default:
                throw ToolError.badInput("这里应该是一个数字")
            }
        }
    }
}

// MARK: - 单位换算

enum UnitConverter {
    enum Dimension: String, CaseIterable {
        case length, mass, temperature, area, volume, speed, data, time
    }

    static let tables: [Dimension: [String: Double]] = [
        .length: [
            "mm": 0.001, "cm": 0.01, "m": 1, "km": 1000,
            "in": 0.0254, "ft": 0.3048, "yd": 0.9144, "mi": 1609.344,
            "里": 500, "尺": 0.3333, "寸": 0.0333
        ],
        .mass: [
            "mg": 0.000001, "g": 0.001, "kg": 1, "t": 1000,
            "oz": 0.0283495, "lb": 0.453592, "斤": 0.5, "两": 0.05
        ],
        .area: [
            "m2": 1, "km2": 1_000_000, "cm2": 0.0001,
            "ha": 10_000, "亩": 666.667, "ft2": 0.092903, "acre": 4046.86
        ],
        .volume: [
            "ml": 0.001, "l": 1, "m3": 1000, "gal": 3.78541, "cup": 0.236588
        ],
        .speed: [
            "m/s": 1, "km/h": 0.277778, "mph": 0.44704, "knot": 0.514444
        ],
        .data: [
            "B": 1, "KB": 1024, "MB": 1_048_576, "GB": 1_073_741_824, "TB": 1_099_511_627_776
        ],
        .time: [
            "s": 1, "min": 60, "h": 3600, "day": 86400, "week": 604800
        ]
    ]

    static func convert(_ value: Double, from: String, to: String) throws -> Double {
        let fromKey = normalize(from)
        let toKey = normalize(to)

        if isTemperature(fromKey) && isTemperature(toKey) {
            return convertTemperature(value, from: fromKey, to: toKey)
        }

        for (_, table) in tables {
            if let fromFactor = table[fromKey], let toFactor = table[toKey] {
                return value * fromFactor / toFactor
            }
        }
        throw ToolError.badInput("不支持的单位组合：\(from) → \(to)")
    }

    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        let aliases: [String: String] = [
            "米": "m", "厘米": "cm", "毫米": "mm", "公里": "km", "千米": "km",
            "英寸": "in", "英尺": "ft", "英里": "mi", "码": "yd",
            "克": "g", "千克": "kg", "公斤": "kg", "吨": "t", "磅": "lb", "盎司": "oz",
            "平方米": "m2", "平方公里": "km2", "公顷": "ha", "英亩": "acre",
            "升": "l", "毫升": "ml", "加仑": "gal",
            "秒": "s", "分钟": "min", "小时": "h", "天": "day", "周": "week",
            "字节": "B", "兆": "MB", "吉": "GB"
        ]
        if let alias = aliases[trimmed] { return alias }
        if lower == "c" || trimmed == "摄氏度" || trimmed == "°c" { return "c" }
        if lower == "f" || trimmed == "华氏度" || trimmed == "°f" { return "f" }
        if lower == "k" || trimmed == "开尔文" { return "k" }
        return lower
    }

    static func isTemperature(_ key: String) -> Bool { ["c", "f", "k"].contains(key) }

    static func convertTemperature(_ value: Double, from: String, to: String) -> Double {
        let celsius: Double
        switch from {
        case "f": celsius = (value - 32) * 5 / 9
        case "k": celsius = value - 273.15
        default: celsius = value
        }
        switch to {
        case "f": return celsius * 9 / 5 + 32
        case "k": return celsius + 273.15
        default: return celsius
        }
    }
}

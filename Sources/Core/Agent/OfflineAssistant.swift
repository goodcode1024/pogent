import Foundation

/// 中文时间表达式解析。离线模式下没有模型可依赖，必须自己认时间。
enum ChineseTime {
    static func parse(_ raw: String, now: Date = Date()) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let iso = DateParsing.date(text) { return iso }
        if let clock = ClockTool.parseClock(text), text.contains(":") { return clock }

        let calendar = Calendar.current
        var dayOffset = 0
        if text.contains("后天") { dayOffset = 2 }
        else if text.contains("明天") || text.contains("明早") || text.contains("明晚") || text.contains("明日") { dayOffset = 1 }

        // “3 小时后”“20 分钟后”
        if let relative = match(#"(\d{1,3})\s*(分钟|分|小时|钟头|天)\s*(?:后|以后|之后)"#, in: text),
           let amount = Int(relative.0) {
            switch relative.1 {
            case "天": return calendar.date(byAdding: .day, value: amount, to: now)
            case "小时", "钟头": return calendar.date(byAdding: .hour, value: amount, to: now)
            default: return calendar.date(byAdding: .minute, value: amount, to: now)
            }
        }

        // “7 点”“7 点半”“19:30”
        guard let clockMatch = match(#"(\d{1,2})\s*[点:：时]\s*(\d{1,2})?\s*(半|刻)?"#, in: text),
              let hourValue = Int(clockMatch.0) else {
            if dayOffset > 0 {
                return calendar.date(byAdding: .day, value: dayOffset, to: now)
            }
            return nil
        }

        var hour = hourValue
        var minute = Int(clockMatch.1 ?? "0") ?? 0
        if clockMatch.2 == "半" { minute = 30 }
        if clockMatch.2 == "刻" { minute = 15 }

        let isAfternoon = text.contains("下午") || text.contains("晚上") || text.contains("傍晚") || text.contains("明晚")
        let isNoon = text.contains("中午")
        let isMorning = text.contains("早上") || text.contains("上午") || text.contains("凌晨") || text.contains("明早")

        if isNoon, hour < 12 { hour += 12 }
        if isAfternoon, hour < 12 { hour += 12 }
        if isMorning, hour == 12 { hour = 0 }
        // “晚上 12 点”按 0 点算
        if text.contains("晚上"), hour == 12 { hour = 0 }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.day = (components.day ?? 1) + dayOffset
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var date = calendar.date(from: components) else { return nil }

        if dayOffset == 0, date < now, !text.contains("昨天") {
            // 说的时刻已经过了，默认指明天。
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    static func match(_ pattern: String, in text: String) -> (String, String, String?)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        func group(_ index: Int) -> String? {
            guard index < match.numberOfRanges,
                  let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let first = group(1) else { return nil }
        return (first, group(2) ?? "0", group(3))
    }

    static func firstNumber(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(-?\d+(?:\.\d+)?)"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[swiftRange])
    }
}

/// 离线大脑：没有 API Key、设备也不支持端侧模型时，仍然能真正干活。
///
/// 它不“假装”理解——认得出的意图直接映射到工具并真的执行，
/// 认不出就老实说现在能做什么，不编答案。
@MainActor
final class OfflineAssistant {
    struct Plan {
        var reply: String
        var calls: [ToolInvocation] = []
        var capabilityHint: String?
    }

    private let workspace: URL
    private let memory: MemoryStore

    init(workspace: URL, memory: MemoryStore) {
        self.workspace = workspace
        self.memory = memory
    }

    func plan(_ input: String) -> Plan {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        // 1. 问候与自我介绍
        if text.isEmpty {
            return Plan(reply: "在。要做什么？")
        }
        if ["你好", "hi", "hello", "在吗", "嗨"].contains(where: { lower.hasPrefix($0) }) {
            return Plan(reply: "在。你可以直接说事：定闹钟、查天气、建提醒、算数、看图片、找文件、管日程。没网也能用。")
        }
        if lower.contains("你能做什么") || lower.contains("帮助") || lower == "help" || lower.contains("会什么") {
            return Plan(reply: Self.capabilitySheet)
        }
        if lower.contains("你是谁") || lower.contains("介绍一下自己") {
            return Plan(reply: "我是 pogent，跑在这台 iPhone 上的智能体。现在没有连大模型，所以在用本机规则引擎：能用系统能力直接办的事都会真的办，办不了的我会直说。")
        }

        // 2. 时间
        if lower.contains("几点") || lower.contains("现在时间") || lower.contains("今天几号") || lower.contains("星期几") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 EEEE HH:mm"
            return Plan(reply: "现在是 \(formatter.string(from: Date()))。")
        }

        // 3. 记忆
        if lower.hasPrefix("记住") || lower.contains("记一下") || lower.contains("帮我记住") {
            let content = text
                .replacingOccurrences(of: "帮我记住", with: "")
                .replacingOccurrences(of: "记住", with: "")
                .replacingOccurrences(of: "记一下", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，")))
            guard !content.isEmpty else { return Plan(reply: "要记住什么？") }
            memory.add(content, kind: content.contains("喜欢") || content.contains("不喜欢") ? .preference : .fact)
            return Plan(reply: "记住了：\(content)")
        }
        if lower.contains("记得") || lower.contains("我说过") || lower.contains("回忆") {
            let results = memory.search(text)
            if results.isEmpty {
                let all = memory.items.prefix(6).map { "• \($0.text)" }
                return Plan(reply: all.isEmpty ? "我还没记住什么。说「记住……」我就会记下来。" : "没找到对应的。我目前记得：\n" + all.joined(separator: "\n"))
            }
            return Plan(reply: results.map { "• \($0.text)" }.joined(separator: "\n"))
        }

        // 4. 计算
        if lower.contains("算") || lower.contains("等于") || isArithmetic(text) {
            let expression = text
                .replacingOccurrences(of: "帮我算一下", with: "")
                .replacingOccurrences(of: "帮我算", with: "")
                .replacingOccurrences(of: "算一下", with: "")
                .replacingOccurrences(of: "等于多少", with: "")
                .replacingOccurrences(of: "等于", with: "")
                .replacingOccurrences(of: "是多少", with: "")
                .replacingOccurrences(of: "？", with: "")
                .replacingOccurrences(of: "?", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = try? Calculator.evaluate(expression) {
                return Plan(reply: "\(expression) = \(Calculator.format(value))")
            }
        }

        // 5. 单位换算
        if lower.contains("换算") || (lower.contains("等于多少") && hasUnit(text)) {
            if let plan = conversionPlan(text) { return plan }
        }

        // 6. 天气
        if lower.contains("天气") || lower.contains("下雨") || lower.contains("气温") || lower.contains("冷不冷") || lower.contains("热不热") {
            var arguments: [String: JSONValue] = ["action": .string("weather")]
            if let city = cityName(text) { arguments["city"] = .string(city) }
            return Plan(reply: "查一下天气。", calls: [ToolInvocation(name: "weather", arguments: .object(arguments))])
        }

        // 7. 闹钟
        if lower.contains("闹钟") || lower.contains("叫醒") || lower.contains("叫我起床") {
            guard let date = ChineseTime.parse(text) else {
                return Plan(reply: "要给个时间，比如「明早 7 点叫我」。")
            }
            return Plan(reply: "好，定在 \(Self.clockText(date))。", calls: [
                ToolInvocation(name: "clock", arguments: .object([
                    "action": .string("alarm"),
                    "time": .string(ISO8601DateFormatter().string(from: date)),
                    "title": .string(lower.contains("起床") ? "起床" : "闹钟")
                ]))
            ])
        }

        // 8. 倒计时
        if lower.contains("倒计时") || lower.contains("计时") || lower.contains("番茄") {
            let minutes = ChineseTime.firstNumber(in: text) ?? 25
            return Plan(reply: "开始 \(Int(minutes)) 分钟倒计时。", calls: [
                ToolInvocation(name: "clock", arguments: .object([
                    "action": .string("timer"),
                    "minutes": .number(minutes),
                    "title": .string("倒计时")
                ]))
            ])
        }

        // 9. 提醒
        if lower.contains("提醒我") {
            guard let date = ChineseTime.parse(text) else {
                return Plan(reply: "要给个时间，比如「明天下午 3 点提醒我开会」。")
            }
            let title = text
                .replacingOccurrences(of: "提醒我", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。：")))
            return Plan(reply: "好，\(Self.clockText(date)) 提醒你。", calls: [
                ToolInvocation(name: "reminders", arguments: .object([
                    "action": .string("create"),
                    "title": .string(title.isEmpty ? "提醒" : title),
                    "due": .string(ISO8601DateFormatter().string(from: date))
                ]))
            ])
        }

        // 10. 日程
        if lower.contains("日程") || lower.contains("日历") || lower.contains("会议") || lower.contains("约了") || lower.contains("加个") {
            guard let date = ChineseTime.parse(text) else {
                return Plan(reply: "要给个时间，比如「明天下午 3 点加个会」。")
            }
            let title = text
                .replacingOccurrences(of: "加个日程", with: "")
                .replacingOccurrences(of: "加个", with: "")
                .replacingOccurrences(of: "日程", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。：")))
            return Plan(reply: "好，加到日历。", calls: [
                ToolInvocation(name: "calendar", arguments: .object([
                    "action": .string("create"),
                    "title": .string(title.isEmpty ? "新日程" : title),
                    "start": .string(ISO8601DateFormatter().string(from: date)),
                    "duration_minutes": .number(60)
                ]))
            ])
        }

        // 11. 设备与硬件
        if lower.contains("电量") || lower.contains("电池") || lower.contains("充电") {
            return Plan(reply: "", calls: [ToolInvocation(name: "battery", arguments: .object(["action": .string("read")]))])
        }
        if lower.contains("内存") || lower.contains("存储") || lower.contains("什么手机") || lower.contains("系统版本") || lower.contains("设备信息") {
            return Plan(reply: "", calls: [ToolInvocation(name: "device_info", arguments: .object([:]))])
        }
        if lower.contains("手电筒") || lower.contains("闪光灯") {
            let on = !(lower.contains("关") || lower.contains("关掉"))
            return Plan(reply: "手电筒\(on ? "开" : "关")了。", calls: [
                ToolInvocation(name: "hardware", arguments: .object([
                    "action": .string("flashlight"), "on": .bool(on)
                ]))
            ])
        }
        if lower.contains("亮度") {
            let value = (ChineseTime.firstNumber(in: text) ?? 50) / 100
            return Plan(reply: "亮度调到 \(Int(value * 100))%。", calls: [
                ToolInvocation(name: "hardware", arguments: .object([
                    "action": .string("brightness"), "value": .number(value)
                ]))
            ])
        }

        // 12. 剪贴板
        if lower.contains("剪贴板") || lower.contains("复制") {
            if lower.contains("写") || lower.contains("放") || lower.contains("设") {
                let content = text.replacingOccurrences(of: "复制", with: "").trimmingCharacters(in: .whitespaces)
                return Plan(reply: "已放进剪贴板。", calls: [
                    ToolInvocation(name: "clipboard", arguments: .object([
                        "action": .string("write"), "text": .string(content)
                    ]))
                ])
            }
            return Plan(reply: "", calls: [ToolInvocation(name: "clipboard", arguments: .object(["action": .string("read")]))])
        }

        // 13. 二维码
        if lower.contains("二维码") {
            let content = text
                .replacingOccurrences(of: "生成", with: "")
                .replacingOccurrences(of: "二维码", with: "")
                .replacingOccurrences(of: "一个", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。：")))
            guard !content.isEmpty else { return Plan(reply: "二维码里要放什么内容？") }
            return Plan(reply: "生成好了，在图库里能看到路径。", calls: [
                ToolInvocation(name: "media_toolbox", arguments: .object([
                    "action": .string("qr"), "text": .string(content)
                ]))
            ])
        }

        // 14. 朗读
        if lower.contains("读出来") || lower.contains("朗读") || lower.contains("念一下") || lower.contains("播报") {
            let content = text
                .replacingOccurrences(of: "读出来", with: "")
                .replacingOccurrences(of: "朗读", with: "")
                .replacingOccurrences(of: "念一下", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。：")))
            guard !content.isEmpty else { return Plan(reply: "要念哪段？") }
            return Plan(reply: "", calls: [
                ToolInvocation(name: "speak", arguments: .object(["text": .string(content)]))
            ])
        }

        // 15. 看图
        if lower.contains("这张图") || lower.contains("识别") || lower.contains("图里") || lower.contains("图片") {
            return Plan(reply: "把图片放进工作区后告诉我文件名，我用本机视觉读它。也可以直接到「能力 → 看图和扫码」拍一张。")
        }

        // 16. 随机
        if lower.contains("随机") || lower.contains("抽一个") || lower.contains("抽个") {
            let range = ChineseTime.firstNumber(in: text).map { Int($0) } ?? 100
            return Plan(reply: "", calls: [
                ToolInvocation(name: "utility", arguments: .object([
                    "action": .string("random"), "min": .number(1), "max": .number(Double(range))
                ]))
            ])
        }

        // 17. 编码与哈希
        if lower.contains("md5") || lower.contains("sha") || lower.contains("哈希") {
            return Plan(reply: "", calls: [
                ToolInvocation(name: "utility", arguments: .object([
                    "action": .string("hash"),
                    "mode": .string(lower.contains("md5") ? "md5" : "sha256"),
                    "text": .string(text)
                ]))
            ])
        }
        if lower.contains("base64") || lower.contains("编码") || lower.contains("解码") {
            return Plan(reply: "", calls: [
                ToolInvocation(name: "utility", arguments: .object([
                    "action": .string("encode"),
                    "mode": .string(lower.contains("解码") ? "decode:base64" : "base64"),
                    "text": .string(text)
                ]))
            ])
        }

        // 18. 文件
        if lower.contains("文件") || lower.contains("目录") || lower.contains("工作区") {
            return Plan(reply: "", calls: [
                ToolInvocation(name: "list_files", arguments: .object(["path": .string(".")]))
            ])
        }

        // 19. 位置
        if lower.contains("我在哪") || lower.contains("我的位置") || lower.contains("定位") {
            return Plan(reply: "", calls: [
                ToolInvocation(name: "location", arguments: .object(["action": .string("current")]))
            ])
        }
        if lower.contains("附近") {
            let query = text.replacingOccurrences(of: "附近", with: "").replacingOccurrences(of: "的", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Plan(reply: "找一下。", calls: [
                ToolInvocation(name: "location", arguments: .object([
                    "action": .string("nearby"),
                    "query": .string(query.isEmpty ? "咖啡" : query)
                ]))
            ])
        }
        if lower.contains("导航") || lower.contains("怎么走") || lower.contains("路线") {
            let destination = text
                .replacingOccurrences(of: "导航到", with: "")
                .replacingOccurrences(of: "导航", with: "")
                .replacingOccurrences(of: "怎么走", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Plan(reply: "打开导航。", calls: [
                ToolInvocation(name: "maps", arguments: .object([
                    "action": .string("directions"), "destination": .string(destination)
                ]))
            ])
        }

        // 20. 联系人
        if lower.contains("电话") || lower.contains("联系方式") || lower.contains("号码") {
            let name = text
                .replacingOccurrences(of: "的电话", with: "")
                .replacingOccurrences(of: "联系方式", with: "")
                .replacingOccurrences(of: "号码", with: "")
                .replacingOccurrences(of: "查一下", with: "")
                .replacingOccurrences(of: "找一下", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。：?？")))
            guard !name.isEmpty else { return Plan(reply: "要找谁？") }
            return Plan(reply: "", calls: [
                ToolInvocation(name: "contacts", arguments: .object([
                    "action": .string("search"), "query": .string(name)
                ]))
            ])
        }

        // 21. 发消息
        if lower.contains("发消息") || lower.contains("发短信") || lower.contains("告诉") {
            return Plan(reply: "发消息需要你确认。告诉我「发给谁」和「说什么」，我会把内容填好，发送键留给你按。")
        }

        // 22. 音乐
        if lower.contains("放歌") || lower.contains("播放") || lower.contains("听歌") || lower.contains("音乐") {
            let query = text
                .replacingOccurrences(of: "放首歌", with: "")
                .replacingOccurrences(of: "放歌", with: "")
                .replacingOccurrences(of: "播放", with: "")
                .replacingOccurrences(of: "我想听", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Plan(reply: "", calls: [
                ToolInvocation(name: "music", arguments: .object(["query": .string(query.isEmpty ? "每日推荐" : query)]))
            ])
        }

        // 23. 搜索
        if lower.hasPrefix("搜") || lower.hasPrefix("查一下") || lower.contains("搜索") {
            let query = text
                .replacingOccurrences(of: "搜一下", with: "")
                .replacingOccurrences(of: "搜索", with: "")
                .replacingOccurrences(of: "查一下", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return Plan(reply: "搜什么？") }
            return Plan(reply: "查一下。", calls: [
                ToolInvocation(name: "web_fetch", arguments: .object([
                    "url": .string("https://duckduckgo.com/html/?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
                ]))
            ])
        }

        // 24. 兜底：诚实说明
        return Plan(
            reply: """
            这句话我现在的本机规则引擎还接不住。

            我在离线状态下能直接办这些：
            定闹钟、倒计时、建提醒、加日程、查天气、算数、单位换算、
            读剪贴板、生成二维码、朗读、查电量、开关手电筒、调亮度、
            定位、找附近、导航、查联系人、放歌、看图片文字、管文件、记忆。

            想要真正自由对话和复杂规划，到「设置 → 模型」填一个 API Key，
            或者换一台支持 Apple 智能的设备用端侧模型。
            """,
            capabilityHint: "offline"
        )
    }

    // MARK: 辅助

    private func isArithmetic(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789+-*/%^()., ×÷（）")
        let filtered = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !filtered.isEmpty else { return false }
        let allAllowed = filtered.allSatisfy { allowed.contains($0) }
        let hasDigit = text.contains { $0.isNumber }
        let hasOperator = text.contains(where: { "+-*/×÷^".contains($0) })
        return allAllowed && hasDigit && hasOperator
    }

    private func hasUnit(_ text: String) -> Bool {
        let units = ["米", "公里", "厘米", "千克", "公斤", "克", "斤", "磅", "摄氏度", "华氏度",
                     "km", "kg", "cm", "mm", "mb", "gb", "tb", "升", "加仑", "英里", "英尺", "小时", "分钟"]
        return units.contains { text.lowercased().contains($0) }
    }

    private func conversionPlan(_ text: String) -> Plan? {
        guard let value = ChineseTime.firstNumber(in: text) else { return nil }
        let pattern = #"(\d+(?:\.\d+)?)\s*([^\s等于多少换算到]{1,6}?)\s*(?:换算成|换算为|等于多少|等于|到|转成)\s*([^\s。？?]{1,6})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let fromRange = Range(match.range(at: 2), in: text),
              let toRange = Range(match.range(at: 3), in: text) else { return nil }
        let from = String(text[fromRange])
        let to = String(text[toRange])
        return Plan(reply: "", calls: [
            ToolInvocation(name: "utility", arguments: .object([
                "action": .string("convert"),
                "value": .number(value),
                "from": .string(from),
                "to": .string(to)
            ]))
        ])
    }

    private func cityName(_ text: String) -> String? {
        let pattern = #"(?:北京|上海|广州|深圳|杭州|成都|重庆|武汉|西安|南京|苏州|天津|长沙|郑州|青岛|厦门|福州|昆明|合肥|济南|沈阳|大连|哈尔滨|三亚|香港|澳门|台北|东京|大阪|首尔|新加坡|伦敦|巴黎|纽约|旧金山|洛杉矶)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static let capabilitySheet = """
    我现在能做的事，分四类：

    **时间与提醒**
    定闹钟、倒计时、建提醒、加日程、查时间、算日期差

    **本机能力**
    查天气、读电量与设备信息、开关手电筒、调亮度、定位、找附近、导航、
    查联系人、读剪贴板、生成二维码、朗读文字、看图识字、识别条码、转写录音

    **本地工具**
    算数、单位换算、正则、JSON 整理、Base64/URL/Hex 编码、哈希、
    文本统计、随机数、PDF 合并拆分、图片缩放裁剪滤镜

    **文件与代码**
    读写文件、列目录、跑 shell、git、Python、预览文件

    要自由对话和复杂规划，去设置里填 API Key；不填也能用上面这些。
    """
}
